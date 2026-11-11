import CloudKitData
import Foundation
import SwiftData

/// Contract violations detected before a local authored transaction commits.
public enum CloudDataTransactionError: Error, Sendable, Equatable {
  /// One authored transaction cannot commit from inside another transaction.
  case nestedTransaction

  /// The model conforms to CloudSyncedModel but is absent from CloudDataSchema.
  case modelNotInSchema(String)

  /// The generated record-name property produced an empty String.
  case emptyRecordName(recordType: String)

  /// Two model types attempted to use the same zone-wide record name.
  case recordNameCollision(
    recordName: String,
    existingRecordType: String,
    requestedRecordType: String
  )

  /// One opaque prepared file token was already committed as another intent.
  case preparedAssetAlreadyConsumed(String)
}

/// Describes whether a committed store transaction changed transport work.
///
/// Local SwiftData state and CloudKit intent deliberately share one transaction
/// API, but only explicit synchronization operations should wake the transport.
enum CloudDataStoreCommitEffect: Sendable, Equatable {
  /// The commit changed only local domain or presentation state.
  case localOnly

  /// The commit created, coalesced, or cancelled package-owned transport work.
  case refreshTransport
}

/// One explicit authored-write transaction over an application's main context.
///
/// Mutate arbitrary domain models through `modelContext`, then call
/// `synchronize(_:)` for every changed synced model. `insert(_:)` and
/// `delete(_:)` combine the common model operation with its outbox intent.
/// The enclosing `CloudDataStore.transaction` performs exactly one save.
@MainActor
public final class CloudDataTransaction {
  /// The store's actor-isolated main context for domain-specific mutations.
  public let modelContext: ModelContext

  private let registry: CloudDataModelRegistry
  private let storeID: CloudDataStoreID
  private let assetFileStore: CloudDataAssetFileStore
  private let now: () -> Date
  private var authoredRevisionsByRecordName: [String: String] = [:]
  private var filesToDeleteAfterCommit = Set<String>()
  private var filesToDeleteAfterRollback = Set<String>()
  private var requiresTransportRefresh = false

  /// The transport consequence accumulated by explicit sync operations.
  var commitEffect: CloudDataStoreCommitEffect {
    requiresTransportRefresh ? .refreshTransport : .localOnly
  }

  init(
    modelContext: ModelContext,
    registry: CloudDataModelRegistry,
    storeID: CloudDataStoreID,
    assetFileStore: CloudDataAssetFileStore,
    now: @escaping () -> Date
  ) {
    self.modelContext = modelContext
    self.registry = registry
    self.storeID = storeID
    self.assetFileStore = assetFileStore
    self.now = now
  }

  /// Inserts a new synchronized model and enqueues its current value for save.
  public func insert<Model: CloudSyncedModel>(_ model: Model) throws {
    modelContext.insert(model)
    try synchronize(model)
  }

  /// Enqueues the current value of an inserted or updated synchronized model.
  public func synchronize<Model: CloudSyncedModel>(_ model: Model) throws {
    guard let registration = registry.registration(for: Model.self) else {
      throw CloudDataTransactionError.modelNotInSchema(String(reflecting: Model.self))
    }
    let snapshot = try registration.makeSnapshot(from: model)
    guard snapshot.recordName.isEmpty == false else {
      throw CloudDataTransactionError.emptyRecordName(
        recordType: registration.descriptor.recordType
      )
    }
    _ = try noteSave(
      recordType: registration.descriptor.recordType,
      recordName: snapshot.recordName
    )
  }

  /// Explicitly preserves a remote asset while enqueuing the model's current
  /// scalar values.
  ///
  /// An already-durable replacement or removal remains pending. This method
  /// never infers intent from a local revision or file-system observation.
  public func preserveAsset<Model: CloudSyncedModel>(
    _ model: Model,
    at keyPath: KeyPath<Model, CloudAssetSlot>
  ) throws {
    let resolved = try resolveAsset(model, at: keyPath)
    _ = try noteSave(
      recordType: resolved.registration.descriptor.recordType,
      recordName: resolved.snapshot.recordName
    )
  }

  /// Replaces one remote asset with an asynchronously prepared immutable file.
  public func replaceAsset<Model: CloudSyncedModel>(
    _ model: Model,
    at keyPath: KeyPath<Model, CloudAssetSlot>,
    with prepared: CloudDataPreparedAssetReplacement
  ) throws {
    let resolved = try resolveAsset(model, at: keyPath)
    guard prepared.reference == resolved.reference else {
      throw CloudDataAssetTransferError.preparedAssetMismatch(
        expected: resolved.reference,
        actual: prepared.reference
      )
    }
    _ = try assetFileStore.requireFileURL(fileID: prepared.fileID)
    guard try fetchStagedAssetFile(id: prepared.fileID) == nil else {
      throw CloudDataTransactionError.preparedAssetAlreadyConsumed(
        prepared.fileID
      )
    }

    let revision = try noteSave(
      recordType: resolved.registration.descriptor.recordType,
      recordName: resolved.snapshot.recordName
    )
    modelContext.insert(
      CloudDataStagedAssetFile(
        id: prepared.fileID,
        direction: .outgoing,
        recordName: resolved.snapshot.recordName,
        fieldKey: resolved.asset.descriptor.key,
        createdAt: now()
      )
    )
    try upsertAssetMutation(
      reference: resolved.reference,
      kind: .replace,
      mutationRevision: revision,
      stagedFileID: prepared.fileID
    )
  }

  /// Replaces one remote asset by synchronously copying an existing local file
  /// into package-owned immutable staging.
  ///
  /// Use this when the authored domain operation already produced a concrete
  /// file before commit. The source is never moved or deleted by the package.
  public func replaceAsset<Model: CloudSyncedModel>(
    _ model: Model,
    at keyPath: KeyPath<Model, CloudAssetSlot>,
    copyingFileAt sourceURL: URL
  ) throws {
    let resolved = try resolveAsset(model, at: keyPath)
    let prepared = try assetFileStore.copyOutgoing(
      from: sourceURL,
      reference: resolved.reference
    )
    do {
      try replaceAsset(model, at: keyPath, with: prepared)
      filesToDeleteAfterRollback.insert(prepared.fileID)
    } catch {
      try? assetFileStore.removeFile(fileID: prepared.fileID)
      throw error
    }
  }

  /// Removes one remote asset field without deleting or inspecting local files.
  public func removeAsset<Model: CloudSyncedModel>(
    _ model: Model,
    at keyPath: KeyPath<Model, CloudAssetSlot>
  ) throws {
    let resolved = try resolveAsset(model, at: keyPath)
    let revision = try noteSave(
      recordType: resolved.registration.descriptor.recordType,
      recordName: resolved.snapshot.recordName
    )
    try upsertAssetMutation(
      reference: resolved.reference,
      kind: .remove,
      mutationRevision: revision,
      stagedFileID: nil
    )
  }

  /// Deletes a synchronized model and records its remote deletion intent.
  ///
  /// An unstaged local insert is canceled instead. If the same record name
  /// may already exist remotely, follow deletion with an explicit tombstone.
  public func delete<Model: CloudSyncedModel>(_ model: Model) throws {
    guard let registration = registry.registration(for: Model.self) else {
      throw CloudDataTransactionError.modelNotInSchema(String(reflecting: Model.self))
    }
    let snapshot = try registration.makeSnapshot(from: model)
    guard snapshot.recordName.isEmpty == false else {
      throw CloudDataTransactionError.emptyRecordName(
        recordType: registration.descriptor.recordType
      )
    }
    try noteDelete(
      recordType: registration.descriptor.recordType,
      recordName: snapshot.recordName
    )
    modelContext.delete(model)
  }

  /// Enqueues a remote tombstone while retaining the local model.
  ///
  /// This supports domain-level logical deletion where local history remains
  /// available for restore even though the CloudKit record must disappear.
  public func tombstone<Model: CloudSyncedModel>(_ model: Model) throws {
    guard let registration = registry.registration(for: Model.self) else {
      throw CloudDataTransactionError.modelNotInSchema(String(reflecting: Model.self))
    }
    let snapshot = try registration.makeSnapshot(from: model)
    guard snapshot.recordName.isEmpty == false else {
      throw CloudDataTransactionError.emptyRecordName(
        recordType: registration.descriptor.recordType
      )
    }
    try noteDelete(
      recordType: registration.descriptor.recordType,
      recordName: snapshot.recordName
    )
  }

  /// Enqueues a remote tombstone when the corresponding model is not loaded
  /// in this store.
  ///
  /// Server-authoritative retention policies can discover records that the
  /// local cache never materialized. The model type still selects and
  /// validates the generated registration, while `recordName` carries the
  /// exact remote identity. An existing delete remains untouched so a repeated
  /// retention pass cannot invalidate an in-flight acknowledgement.
  public func tombstone<Model: CloudSyncedModel>(
    _ modelType: Model.Type,
    recordName: String,
    orderedAt: Date? = nil
  ) throws {
    guard let registration = registry.registration(for: modelType) else {
      throw CloudDataTransactionError.modelNotInSchema(String(reflecting: modelType))
    }
    guard recordName.isEmpty == false else {
      throw CloudDataTransactionError.emptyRecordName(
        recordType: registration.descriptor.recordType
      )
    }
    if let pending = try fetchPending(recordName: recordName), pending.kind == .delete {
      try validateRecordType(
        pending.recordType,
        requestedRecordType: registration.descriptor.recordType,
        recordName: recordName
      )
      requiresTransportRefresh = true
      return
    }
    try noteDelete(
      recordType: registration.descriptor.recordType,
      recordName: recordName,
      enqueuedAt: orderedAt ?? now()
    )
  }

  private func noteSave(recordType: String, recordName: String) throws -> String {
    try validateMetadataRecordType(recordType, recordName: recordName)
    requiresTransportRefresh = true
    if let revision = authoredRevisionsByRecordName[recordName] {
      return revision
    }
    let revision = UUID().uuidString
    if let pending = try fetchPending(recordName: recordName) {
      try validateRecordType(
        pending.recordType,
        requestedRecordType: recordType,
        recordName: recordName
      )
      pending.recordType = recordType
      pending.kind = .save
      pending.revisionRawValue = revision
      pending.enqueuedAt = now()
      pending.stagedAt = nil
      pending.stagedRevisionRawValue = nil
      pending.latestErrorCategoryRawValue = nil
      pending.latestErrorMessage = nil
      pending.latestErrorAt = nil
    } else {
      modelContext.insert(
        CloudDataPendingMutation(
          recordName: recordName,
          recordType: recordType,
          kind: .save,
          revision: revision,
          enqueuedAt: now()
        )
      )
    }
    try carryPendingAssetMutations(
      recordName: recordName,
      toRevision: revision
    )
    authoredRevisionsByRecordName[recordName] = revision
    return revision
  }

  private func noteDelete(
    recordType: String,
    recordName: String,
    enqueuedAt: Date? = nil
  ) throws {
    let pending = try fetchPending(recordName: recordName)
    let metadata = try fetchMetadata(recordName: recordName)

    if let pending {
      try validateRecordType(
        pending.recordType,
        requestedRecordType: recordType,
        recordName: recordName
      )
    }
    if let metadata {
      try validateRecordType(
        metadata.recordType,
        requestedRecordType: recordType,
        recordName: recordName
      )
    }
    requiresTransportRefresh = true
    try deleteUnresolvedRelationships(
      recordType: recordType,
      recordName: recordName
    )
    try deletePendingAssetInstalls(recordName: recordName)

    // A never-staged local insert has no server record to delete.
    if metadata == nil,
      let pending,
      pending.kind == .save,
      pending.stagedAt == nil
    {
      try deletePendingAssetMutations(
        recordName: recordName,
        deleteStagedFiles: true
      )
      modelContext.delete(pending)
      return
    }

    let revision = UUID().uuidString
    if let pending {
      pending.kind = .delete
      pending.revisionRawValue = revision
      pending.enqueuedAt = enqueuedAt ?? now()
      pending.stagedAt = nil
      pending.stagedRevisionRawValue = nil
      pending.latestErrorCategoryRawValue = nil
      pending.latestErrorMessage = nil
      pending.latestErrorAt = nil
    } else {
      modelContext.insert(
        CloudDataPendingMutation(
          recordName: recordName,
          recordType: recordType,
          kind: .delete,
          revision: revision,
          enqueuedAt: enqueuedAt ?? now()
        )
      )
    }
    authoredRevisionsByRecordName[recordName] = revision
    try deletePendingAssetMutations(
      recordName: recordName,
      deleteStagedFiles: false
    )
  }

  private func resolveAsset<Model: CloudSyncedModel>(
    _ model: Model,
    at keyPath: KeyPath<Model, CloudAssetSlot>
  ) throws -> (
    registration: CloudModelRegistration,
    snapshot: CloudRecordSnapshot,
    asset: CloudAssetRegistration,
    reference: CloudDataAssetReference
  ) {
    guard let registration = registry.registration(for: Model.self) else {
      throw CloudDataTransactionError.modelNotInSchema(String(reflecting: Model.self))
    }
    let snapshot = try registration.makeSnapshot(from: model)
    guard snapshot.recordName.isEmpty == false else {
      throw CloudDataTransactionError.emptyRecordName(
        recordType: registration.descriptor.recordType
      )
    }
    guard let asset = registration.asset(matching: keyPath) else {
      throw CloudDataAssetTransferError.assetSlotNotRegistered(
        recordType: registration.descriptor.recordType
      )
    }
    let slot = try asset.slot(from: model)
    guard slot.localIdentifier.isEmpty == false else {
      throw CloudDataAssetTransferError.emptyLocalIdentifier(
        recordType: registration.descriptor.recordType,
        fieldKey: asset.descriptor.key
      )
    }
    return (
      registration,
      snapshot,
      asset,
      CloudDataAssetReference(
        storeID: storeID,
        recordType: registration.descriptor.recordType,
        recordName: snapshot.recordName,
        fieldKey: asset.descriptor.key,
        localIdentifier: slot.localIdentifier
      )
    )
  }

  func assetReference<Model: CloudSyncedModel>(
    for model: Model,
    at keyPath: KeyPath<Model, CloudAssetSlot>
  ) throws -> CloudDataAssetReference {
    try resolveAsset(model, at: keyPath).reference
  }

  private func upsertAssetMutation(
    reference: CloudDataAssetReference,
    kind: CloudDataAssetMutationKind,
    mutationRevision: String,
    stagedFileID: String?
  ) throws {
    let identity = CloudDataPendingAssetMutation.makeIdentity(
      recordName: reference.recordName,
      fieldKey: reference.fieldKey
    )
    if let mutation = try fetchPendingAssetMutation(identity: identity) {
      mutation.recordType = reference.recordType
      mutation.localIdentifier = reference.localIdentifier
      mutation.kind = kind
      mutation.mutationRevision = mutationRevision
      mutation.stagedFileID = stagedFileID
      mutation.enqueuedAt = now()
    } else {
      modelContext.insert(
        CloudDataPendingAssetMutation(
          recordType: reference.recordType,
          recordName: reference.recordName,
          fieldKey: reference.fieldKey,
          localIdentifier: reference.localIdentifier,
          kind: kind,
          mutationRevision: mutationRevision,
          stagedFileID: stagedFileID,
          enqueuedAt: now()
        )
      )
    }
  }

  private func carryPendingAssetMutations(
    recordName: String,
    toRevision revision: String
  ) throws {
    var descriptor = FetchDescriptor<CloudDataPendingAssetMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.includePendingChanges = true
    for mutation in try modelContext.fetch(descriptor) {
      mutation.mutationRevision = revision
    }
  }

  private func deletePendingAssetMutations(
    recordName: String,
    deleteStagedFiles: Bool
  ) throws {
    var descriptor = FetchDescriptor<CloudDataPendingAssetMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.includePendingChanges = true
    for mutation in try modelContext.fetch(descriptor) {
      if deleteStagedFiles, let fileID = mutation.stagedFileID {
        if let file = try fetchStagedAssetFile(id: fileID) {
          modelContext.delete(file)
        }
        filesToDeleteAfterCommit.insert(fileID)
      }
      modelContext.delete(mutation)
    }
  }

  private func deletePendingAssetInstalls(recordName: String) throws {
    var descriptor = FetchDescriptor<CloudDataPendingAssetInstall>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.includePendingChanges = true
    for install in try modelContext.fetch(descriptor) {
      if let fileID = install.stagedFileID {
        if let file = try fetchStagedAssetFile(id: fileID) {
          modelContext.delete(file)
        }
        filesToDeleteAfterCommit.insert(fileID)
      }
      modelContext.delete(install)
    }
  }

  private func validateMetadataRecordType(
    _ requestedRecordType: String,
    recordName: String
  ) throws {
    guard let metadata = try fetchMetadata(recordName: recordName) else { return }
    try validateRecordType(
      metadata.recordType,
      requestedRecordType: requestedRecordType,
      recordName: recordName
    )
  }

  private func validateRecordType(
    _ existingRecordType: String,
    requestedRecordType: String,
    recordName: String
  ) throws {
    guard existingRecordType != requestedRecordType else { return }
    throw CloudDataTransactionError.recordNameCollision(
      recordName: recordName,
      existingRecordType: existingRecordType,
      requestedRecordType: requestedRecordType
    )
  }

  private func fetchPending(recordName: String) throws -> CloudDataPendingMutation? {
    var descriptor = FetchDescriptor<CloudDataPendingMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchMetadata(recordName: String) throws -> CloudDataSyncMetadata? {
    var descriptor = FetchDescriptor<CloudDataSyncMetadata>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchPendingAssetMutation(
    identity: String
  ) throws -> CloudDataPendingAssetMutation? {
    var descriptor = FetchDescriptor<CloudDataPendingAssetMutation>(
      predicate: #Predicate { $0.identity == identity }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = true
    return try modelContext.fetch(descriptor).first
  }

  private func fetchStagedAssetFile(id: String) throws -> CloudDataStagedAssetFile? {
    var descriptor = FetchDescriptor<CloudDataStagedAssetFile>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = true
    return try modelContext.fetch(descriptor).first
  }

  private func deleteUnresolvedRelationships(
    recordType: String,
    recordName: String
  ) throws {
    var descriptor = FetchDescriptor<CloudDataUnresolvedRelationship>()
    descriptor.includePendingChanges = true
    for relationship in try modelContext.fetch(descriptor)
    where
      (relationship.sourceRecordType == recordType
      && relationship.sourceRecordName == recordName)
      || (relationship.targetRecordType == recordType
        && relationship.targetRecordName == recordName)
    {
      modelContext.delete(relationship)
    }
  }

  func didCommit() {
    for fileID in filesToDeleteAfterCommit {
      try? assetFileStore.removeFile(fileID: fileID)
    }
    filesToDeleteAfterCommit.removeAll()
    filesToDeleteAfterRollback.removeAll()
  }

  func didRollback() {
    for fileID in filesToDeleteAfterRollback {
      try? assetFileStore.removeFile(fileID: fileID)
    }
    filesToDeleteAfterRollback.removeAll()
  }
}

/// A stable local store handle returned by `CloudKitDataStack`.
///
/// The same `ModelContainer` instance is retained for the process lifetime.
/// Application-authored synchronized writes must use `transaction`; the stack
/// cannot intercept arbitrary saves performed through another context.
@MainActor
public final class CloudDataStore {
  /// The consumer-defined stable local store identity.
  public let id: CloudDataStoreID

  /// The process-stable container shared by SwiftUI and sync-side contexts.
  public let modelContainer: ModelContainer

  let configuration: CloudDataStoreConfiguration
  let syncDatabase: CloudDataStoreDatabase

  private let registry: CloudDataModelRegistry
  private let assetStore: CloudDataAssetStore?
  private let storePolicy: CloudDataStorePolicy
  private let assetFileStore: CloudDataAssetFileStore
  private let storeLock: CloudDataStoreLock
  private var commitHandler:
    (@MainActor (CloudDataStoreID, CloudDataStoreMetrics, CloudDataStoreCommitEffect) -> Void)?
  private var isPerformingTransaction = false

  init(
    configuration: CloudDataStoreConfiguration,
    modelContainer: ModelContainer,
    registry: CloudDataModelRegistry,
    assetStore: CloudDataAssetStore?,
    storePolicy: CloudDataStorePolicy,
    assetFileStore: CloudDataAssetFileStore,
    storeLock: CloudDataStoreLock
  ) {
    self.id = configuration.id
    self.configuration = configuration
    self.modelContainer = modelContainer
    self.registry = registry
    self.assetStore = assetStore
    self.storePolicy = storePolicy
    self.assetFileStore = assetFileStore
    self.storeLock = storeLock
    self.modelContainer.mainContext.autosaveEnabled = false
    self.syncDatabase = CloudDataStoreDatabase(
      modelContainer: modelContainer,
      registry: registry,
      storeID: configuration.id,
      assetStore: assetStore,
      storePolicy: storePolicy,
      assetFileStore: assetFileStore,
      storeLock: storeLock
    )
  }

  /// Asynchronously creates an immutable package staging file for replacement.
  ///
  /// Consume the returned token through `CloudDataTransaction.replaceAsset`.
  /// If the token is abandoned, startup recovery removes its untracked file.
  public func prepareAssetReplacement<Model: CloudSyncedModel>(
    for model: Model,
    at keyPath: KeyPath<Model, CloudAssetSlot>
  ) async throws -> CloudDataPreparedAssetReplacement {
    guard let assetStore else {
      throw CloudDataAssetTransferError.assetStoreUnavailable
    }
    let transaction = CloudDataTransaction(
      modelContext: modelContainer.mainContext,
      registry: registry,
      storeID: id,
      assetFileStore: assetFileStore,
      now: { .now }
    )
    let resolved = try transaction.assetReference(for: model, at: keyPath)
    return try await assetFileStore.materializeOutgoing(
      reference: resolved,
      using: assetStore
    )
  }

  /// Performs arbitrary domain changes plus explicit sync intents in one save.
  ///
  /// After acquiring the store's coordination boundary, this method discards
  /// cached snapshots in the process-stable main context. That makes a
  /// fetch-then-mutate command observe commits from another app-group process
  /// while preserving main-context model identity for SwiftUI callers.
  /// Throwing rolls back durable content and outbox together. Already-held
  /// model properties can retain attempted values; read a fresh context when
  /// checking durable state after failure.
  @discardableResult
  public func transaction<Result>(
    _ operation: (CloudDataTransaction) throws -> Result
  ) throws -> Result {
    try performTransaction(
      modelContext: modelContainer.mainContext,
      refreshBeforeOperation: true,
      operation
    )
  }

  /// Performs one authored transaction in a newly-created context.
  ///
  /// Consumers that share a SQLite file with extensions should use this form
  /// for fetch-then-mutate commands so every invocation starts from current
  /// durable state after acquiring its cross-process coordination boundary.
  @discardableResult
  public func transactionWithFreshContext<Result>(
    _ operation: (CloudDataTransaction) throws -> Result
  ) throws -> Result {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    return try performTransaction(
      modelContext: context,
      refreshBeforeOperation: false,
      operation
    )
  }

  private func performTransaction<Result>(
    modelContext context: ModelContext,
    refreshBeforeOperation: Bool,
    _ operation: (CloudDataTransaction) throws -> Result
  ) throws -> Result {
    guard isPerformingTransaction == false else {
      throw CloudDataTransactionError.nestedTransaction
    }
    isPerformingTransaction = true
    defer { isPerformingTransaction = false }

    return try storeLock.withLock {
      if refreshBeforeOperation {
        Self.refresh(context)
      }
      let transaction = CloudDataTransaction(
        modelContext: context,
        registry: registry,
        storeID: id,
        assetFileStore: assetFileStore,
        now: { .now }
      )

      do {
        let result = try operation(transaction)
        let metrics = try Self.metrics(in: context)
        try context.save()
        transaction.didCommit()
        commitHandler?(id, metrics, transaction.commitEffect)
        return result
      } catch {
        context.rollback()
        transaction.didRollback()
        throw error
      }
    }
  }

  /// Current durable outbox depth, primarily for diagnostics and tests.
  public func pendingMutationCount() throws -> Int {
    try storeLock.withLock {
      Self.refresh(modelContainer.mainContext)
      return try modelContainer.mainContext.fetchCount(
        FetchDescriptor<CloudDataPendingMutation>()
      )
    }
  }

  /// Current durable outbox entries without exposing package system models.
  public func pendingMutations() throws -> [CloudDataPendingMutationSnapshot] {
    try storeLock.withLock {
      Self.refresh(modelContainer.mainContext)
      let descriptor = FetchDescriptor<CloudDataPendingMutation>(
        sortBy: [
          SortDescriptor(\.enqueuedAt),
          SortDescriptor(\.recordName),
        ]
      )
      return try modelContainer.mainContext.fetch(descriptor).map { mutation in
        guard let kind = mutation.kind else {
          throw CloudDataStoreRuntimeError.corruptMutationKind(
            recordName: mutation.recordName,
            rawValue: mutation.kindRawValue
          )
        }
        return CloudDataPendingMutationSnapshot(
          recordName: mutation.recordName,
          recordType: mutation.recordType,
          kind: kind,
          enqueuedAt: mutation.enqueuedAt,
          stagedAt: mutation.stagedAt,
          latestErrorCategory: mutation.latestErrorCategoryRawValue.flatMap(
            CloudDataErrorCategory.init(rawValue:)
          ),
          latestErrorMessage: mutation.latestErrorMessage,
          latestErrorAt: mutation.latestErrorAt
        )
      }
    }
  }

  func currentMetrics() throws -> CloudDataStoreMetrics {
    try storeLock.withLock {
      Self.refresh(modelContainer.mainContext)
      return try Self.metrics(in: modelContainer.mainContext)
    }
  }

  func setCommitHandler(
    _ handler:
      @escaping @MainActor (
        CloudDataStoreID,
        CloudDataStoreMetrics,
        CloudDataStoreCommitEffect
      ) -> Void
  ) {
    commitHandler = handler
  }

  private static func metrics(in context: ModelContext) throws -> CloudDataStoreMetrics {
    var descriptor = FetchDescriptor<CloudDataPendingMutation>()
    descriptor.includePendingChanges = true
    let mutations = try context.fetch(descriptor)
    var assetMutationDescriptor = FetchDescriptor<CloudDataPendingAssetMutation>()
    assetMutationDescriptor.includePendingChanges = true
    var assetInstallDescriptor = FetchDescriptor<CloudDataPendingAssetInstall>()
    assetInstallDescriptor.includePendingChanges = true
    return CloudDataStoreMetrics(
      pendingCount: mutations.count,
      stagedCount: mutations.count { $0.stagedAt != nil },
      pendingAssetTransferCount:
        try context.fetchCount(assetMutationDescriptor)
        + context.fetchCount(assetInstallDescriptor)
    )
  }

  /// Invalidates one context only after the shared store lock is held.
  private static func refresh(_ context: ModelContext) {
    context.rollback()
    context.processPendingChanges()
  }
}

/// Serializes authored and sync-side transactions that share one container.
/// Cross-process coordination remains a consumer integration responsibility.
final class CloudDataStoreLock: @unchecked Sendable {
  private let lock = NSRecursiveLock()

  private let coordination: CloudDataStoreCoordination

  init(coordination: CloudDataStoreCoordination) {
    self.coordination = coordination
  }

  func withLock<Result>(_ operation: () throws -> Result) throws -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try coordination.withCriticalSection(operation)
  }
}
