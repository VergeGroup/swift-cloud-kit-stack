import CloudKitData
import Foundation
import SwiftData

/// The integrated SwiftData + CloudKit composition root.
///
/// Initialization opens every known local store and installs the library's
/// outbox/metadata entities. `start()` independently enables the selected
/// transport; local containers and transactions remain usable in offline,
/// signed-out, and degraded states.
@MainActor
public final class CloudKitDataStack {
  /// The consumer model schema shared by local stores and record adapters.
  public let schema: CloudDataSchema

  /// The UI-facing local/transport read model owned by this stack.
  public let observation: CloudDataSyncObservation

  private let stores: CloudDataStoreDirectory
  private let transport: CloudDataTransportConfiguration
  private let assetStore: CloudDataAssetStore?
  private let storePolicy: CloudDataStorePolicy
  private let eventHandler: CloudDataTransportEventHandler
  private let registry: CloudDataModelRegistry
  private let combinedSwiftDataSchema: Schema
  private var storesByID: [CloudDataStoreID: CloudDataStore] = [:]
  private var storesByRemoteZone: [CloudDataRemoteZone: CloudDataStore] = [:]
  private var storesByFileURL: [URL: CloudDataStore] = [:]
  private var coordinator: CloudKitTransportCoordinator?
  private var hasStarted = false

  /// Opens known local stores and prepares the selected transport configuration.
  public init(
    schema: CloudDataSchema,
    stores: CloudDataStoreDirectory,
    transport: CloudDataTransportConfiguration,
    assetStore: CloudDataAssetStore? = nil,
    storePolicy: CloudDataStorePolicy = .generated,
    eventHandler: CloudDataTransportEventHandler = .none
  ) throws {
    try Self.validate(stores: stores, transport: transport)
    if case .cloudKit = transport.storage,
      schema.registrations.contains(where: { $0.assets.isEmpty == false }),
      assetStore == nil
    {
      throw CloudDataStackSetupError.assetStoreRequired
    }

    self.schema = schema
    self.stores = stores
    self.transport = transport
    self.assetStore = assetStore
    self.storePolicy = storePolicy
    self.eventHandler = eventHandler
    self.registry = CloudDataModelRegistry(schema: schema)
    self.combinedSwiftDataSchema = Schema(
      schema.modelTypes + CloudDataSystemSchema.modelTypes,
      version: schema.version
    )

    let transportScopes = Self.databaseScopes(
      stores: stores,
      transport: transport
    )
    self.observation = CloudDataSyncObservation(
      stores: stores.knownStores,
      transportIsOffline: transport.isOffline,
      databaseScopes: transportScopes
    )

    for configuration in stores.knownStores {
      _ = try openStoreInternal(configuration)
    }
  }

  /// Stable IDs for every currently-open local store.
  public var storeIDs: [CloudDataStoreID] {
    storesByID.keys.sorted { $0.rawValue < $1.rawValue }
  }

  /// Returns the process-stable local store handle for an exact ID.
  public func store(for id: CloudDataStoreID) -> CloudDataStore? {
    storesByID[id]
  }

  /// Opens and registers a local store discovered after stack initialization.
  ///
  /// Repeating the exact configuration returns the process-stable handle.
  /// A conflicting store ID, file, or remote route fails before opening a
  /// second container.
  @discardableResult
  public func openStore(
    _ configuration: CloudDataStoreConfiguration
  ) throws -> CloudDataStore {
    try openStoreInternal(configuration)
  }

  /// Deletes the configured store's exact remote custom zone.
  ///
  /// This is the transport half of a domain delete. The consumer remains
  /// responsible for releasing model references and removing its local files.
  public func deleteRemoteZone(for id: CloudDataStoreID) async throws {
    guard let store = storesByID[id] else { return }
    guard let coordinator else {
      if transport.isOffline {
        throw CloudDataTransportOperationError.offline
      }
      throw CloudDataTransportOperationError.notStarted
    }
    try await coordinator.deleteRemoteZone(store.configuration.remoteZone)
  }

  /// Releases the stack's strong references to one local store and route.
  ///
  /// Existing consumer-held model objects still retain their container; callers
  /// must drop those references before deleting the SQLite directory.
  @discardableResult
  public func discardStore(for id: CloudDataStoreID) async -> Bool {
    guard let store = storesByID.removeValue(forKey: id) else { return false }
    storesByRemoteZone.removeValue(forKey: store.configuration.remoteZone)
    if case .file(let url) = store.configuration.location {
      storesByFileURL.removeValue(forKey: Self.normalizedStoreFileURL(url))
    }
    observation.removeLocalStore(id)
    await coordinator?.discardRoute(store.configuration.remoteZone)
    return true
  }

  /// Starts transport ownership without waiting for network convergence.
  public func start() async {
    guard hasStarted == false else { return }
    hasStarted = true
    await recoverAssets(operation: "startup asset recovery")
    await repairRelationships(operation: "startup relationship repair")

    switch transport.storage {
    case .offline:
      observation.markTransportOffline()

    case .cloudKit(
      let containerIdentifier,
      let databaseScopes,
      let subscriptionIDs,
      let automaticallySync
    ):
      observation.markTransportStarting()
      let routes = storesByID.values.map(CloudDataStoreRoute.init(store:))
      let coordinator = CloudKitTransportCoordinator(
        configuration: .init(
          containerIdentifier: containerIdentifier,
          databaseScopes: databaseScopes,
          subscriptionIDs: subscriptionIDs,
          automaticallySync: automaticallySync
        ),
        descriptorsByRecordType: registry.descriptorsByRecordType,
        stateStore: CloudDataEngineStateStore(
          directoryURL: stores.engineStateDirectoryURL,
          containerIdentifier: containerIdentifier,
          wireSchemaFingerprint: schema.wireSchemaFingerprint,
          replayGeneration: schema.replayGeneration
        ),
        initialRoutes: routes,
        routeStore: { [weak self] remoteZone in
          guard let self else { return nil }
          return try await self.routeStore(for: remoteZone)
        },
        notifyRemoteZoneRemoval: { [stores] remoteZone, reason in
          await stores.notifyRemoteZoneRemoval(remoteZone, reason: reason)
        },
        observation: observation,
        eventHandler: eventHandler
      )
      self.coordinator = coordinator
      await coordinator.start()
    }
  }

  /// Resolves the current CloudKit account as a transport-neutral value.
  public func currentAccountIdentifierLookup() async throws
    -> CloudDataAccountIdentifierLookup
  {
    guard transport.isOffline == false else {
      throw CloudDataTransportOperationError.offline
    }
    guard let coordinator else {
      throw CloudDataTransportOperationError.notStarted
    }
    return await coordinator.currentAccountIdentifierLookup()
  }

  /// Enumerates every custom zone in the configured CloudKit databases.
  ///
  /// This is an isolated inspection for launch discovery and diagnostics. It
  /// does not advance CKSyncEngine tokens or materialize local stores.
  public func remoteZones() async throws -> [CloudDataRemoteZone] {
    guard transport.isOffline == false else {
      throw CloudDataTransportOperationError.offline
    }
    guard let coordinator else {
      throw CloudDataTransportOperationError.notStarted
    }
    return try await coordinator.remoteZones()
  }

  /// Counts the currently-present records in one exact remote custom zone.
  ///
  /// The probe owns a disposable change token and leaves both engine state and
  /// local SwiftData rows untouched.
  public func remoteRecordCounts(
    in remoteZone: CloudDataRemoteZone
  ) async throws -> CloudDataRemoteRecordCounts {
    guard transport.isOffline == false else {
      throw CloudDataTransportOperationError.offline
    }
    guard let coordinator else {
      throw CloudDataTransportOperationError.notStarted
    }
    return try await coordinator.remoteRecordCounts(in: remoteZone)
  }

  /// Explicitly asks every configured engine to fetch current changes.
  public func fetchChanges() async throws {
    guard transport.isOffline == false else {
      throw CloudDataTransportOperationError.offline
    }
    guard let coordinator else {
      throw CloudDataTransportOperationError.notStarted
    }
    try await coordinator.fetchChanges()
  }

  /// Reseeds durable work and explicitly asks each engine to send it.
  public func sendChanges() async throws {
    guard transport.isOffline == false else {
      throw CloudDataTransportOperationError.offline
    }
    guard let coordinator else {
      throw CloudDataTransportOperationError.notStarted
    }
    try await coordinator.sendChanges()
  }

  /// Restarts clean transport engines after the application resolves an
  /// account change for its retained local data.
  ///
  /// Calling this method authorizes the current local outbox to synchronize
  /// with the now-current iCloud account. If the product instead deletes or
  /// replaces account-scoped stores, construct a new stack after that work.
  public func resumeTransportAfterAccountChange() async throws {
    guard transport.isOffline == false else {
      throw CloudDataTransportOperationError.offline
    }
    guard let coordinator else {
      throw CloudDataTransportOperationError.notStarted
    }
    try await coordinator.resumeAfterAccountChange()
  }

  /// Recomputes local pending depth and reseeds engine pending sets.
  ///
  /// Call this on app/extension activation to recover writes authored by
  /// another process that could not signal this stack instance directly.
  public func rescanPendingChanges() async {
    await recoverAssets(operation: "asset rescan")
    await repairRelationships(operation: "relationship rescan")
    for store in storesByID.values {
      do {
        let metrics = try store.currentMetrics()
        observation.updateStoreMetrics(store.id, metrics: metrics)
      } catch {
        observation.record(
          .init(
            category: .localStore,
            operation: "rescan pending changes",
            message: String(error.localizedDescription.prefix(500)),
            databaseScope: store.configuration.remoteZone.databaseScope,
            zoneName: store.configuration.remoteZone.zoneID.zoneName
          )
        )
      }
    }
    await coordinator?.reseedPendingChanges(resetStaging: false)
  }

  private func repairRelationships(operation: String) async {
    for store in storesByID.values {
      do {
        try await store.syncDatabase.repairUnresolvedRelationships()
      } catch {
        observation.record(
          .init(
            category: .importFailure,
            operation: operation,
            message: String(error.localizedDescription.prefix(500)),
            databaseScope: store.configuration.remoteZone.databaseScope,
            zoneName: store.configuration.remoteZone.zoneID.zoneName
          )
        )
      }
    }
  }

  private func recoverAssets(operation: String) async {
    for store in storesByID.values {
      do {
        try await store.syncDatabase.recoverAssetTransfers()
        let metrics = try await store.syncDatabase.metrics()
        observation.updateStoreMetrics(store.id, metrics: metrics)
      } catch {
        if let metrics = try? await store.syncDatabase.metrics() {
          observation.updateStoreMetrics(store.id, metrics: metrics)
        }
        observation.record(
          .init(
            category: .importFailure,
            operation: operation,
            message: String(error.localizedDescription.prefix(500)),
            databaseScope: store.configuration.remoteZone.databaseScope,
            zoneName: store.configuration.remoteZone.zoneID.zoneName
          )
        )
      }
    }
  }

  private func openStoreInternal(
    _ configuration: CloudDataStoreConfiguration
  ) throws -> CloudDataStore {
    try Self.validate(store: configuration, transport: transport)
    if let existing = storesByID[configuration.id] {
      guard existing.configuration == configuration else {
        throw CloudDataStackSetupError.duplicateStoreID(configuration.id)
      }
      return existing
    }
    if let existing = storesByRemoteZone[configuration.remoteZone] {
      throw CloudDataStackSetupError.duplicateRemoteZone(
        existing.configuration.remoteZone
      )
    }
    if case .file(let url) = configuration.location {
      let normalizedURL = Self.normalizedStoreFileURL(url)
      if storesByFileURL[normalizedURL] != nil {
        throw CloudDataStackSetupError.duplicateStoreFileURL(normalizedURL)
      }
    }

    do {
      return try makeStore(configuration)
    } catch let error as CloudDataStackSetupError {
      guard case .localStoreOpenFailed = error else {
        throw error
      }

      let recoveryAction = try stores.recoverLocalStoreOpenFailure(
        configuration: configuration,
        error: error
      )
      switch recoveryAction {
      case .decline:
        throw error
      case .retry:
        break
      case .retryAndInvalidateTransportState:
        try invalidateTransportStateForLocalStoreRecovery()
      }

      // A consumer-approved recovery is bounded to one retry. A second failure
      // is surfaced so a destructive or ineffective policy cannot loop.
      return try makeStore(configuration)
    }
  }

  private func invalidateTransportStateForLocalStoreRecovery() throws {
    guard
      case .cloudKit(let containerIdentifier, _, _, _) = transport.storage
    else {
      return
    }
    try CloudDataEngineStateStore(
      directoryURL: stores.engineStateDirectoryURL,
      containerIdentifier: containerIdentifier,
      wireSchemaFingerprint: schema.wireSchemaFingerprint,
      replayGeneration: schema.replayGeneration
    ).removeAllEngineStates()
  }

  private func makeStore(
    _ configuration: CloudDataStoreConfiguration
  ) throws -> CloudDataStore {
    do {
      let modelConfiguration: ModelConfiguration
      switch configuration.location {
      case .inMemory:
        modelConfiguration = ModelConfiguration(
          schema: combinedSwiftDataSchema,
          isStoredInMemoryOnly: true,
          cloudKitDatabase: .none
        )

      case .file(let url):
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        modelConfiguration = ModelConfiguration(
          nil,
          schema: combinedSwiftDataSchema,
          url: url,
          cloudKitDatabase: .none
        )
      }

      let container = try ModelContainer(
        for: combinedSwiftDataSchema,
        configurations: [modelConfiguration]
      )
      let store = CloudDataStore(
        configuration: configuration,
        modelContainer: container,
        registry: registry,
        assetStore: assetStore,
        storePolicy: storePolicy,
        assetFileStore: CloudDataAssetFileStore(
          rootDirectoryURL: stores.engineStateDirectoryURL,
          storeID: configuration.id
        ),
        storeLock: CloudDataStoreLock(
          coordination: stores.coordination(for: configuration.id)
        )
      )
      let metrics = try store.currentMetrics()
      store.setCommitHandler { [weak self] storeID, metrics, effect in
        self?.handleLocalCommit(
          storeID: storeID,
          metrics: metrics,
          effect: effect
        )
      }
      storesByID[configuration.id] = store
      storesByRemoteZone[configuration.remoteZone] = store
      if case .file(let url) = configuration.location {
        storesByFileURL[Self.normalizedStoreFileURL(url)] = store
      }
      observation.markLocalStoreReady(
        configuration.id,
        scope: configuration.remoteZone.databaseScope,
        metrics: metrics
      )
      return store
    } catch let error as CloudDataStackSetupError {
      observation.markLocalStoreFailed(
        configuration.id,
        scope: configuration.remoteZone.databaseScope,
        error: .init(
          category: .localStore,
          operation: "open local store",
          message: String(describing: error),
          databaseScope: configuration.remoteZone.databaseScope,
          zoneName: configuration.remoteZone.zoneID.zoneName
        )
      )
      throw error
    } catch {
      let setupError = CloudDataStackSetupError.localStoreOpenFailed(
        storeID: configuration.id,
        message: error.localizedDescription
      )
      observation.markLocalStoreFailed(
        configuration.id,
        scope: configuration.remoteZone.databaseScope,
        error: .init(
          category: .localStore,
          operation: "open local store",
          message: error.localizedDescription,
          databaseScope: configuration.remoteZone.databaseScope,
          zoneName: configuration.remoteZone.zoneID.zoneName
        )
      )
      throw setupError
    }
  }

  private func routeStore(
    for remoteZone: CloudDataRemoteZone
  ) async throws -> CloudDataStoreRoute? {
    if let existing = storesByRemoteZone[remoteZone] {
      return CloudDataStoreRoute(store: existing)
    }
    guard let configuration = try await stores.materializeStore(for: remoteZone) else {
      return nil
    }
    guard configuration.remoteZone == remoteZone else {
      throw CloudDataStackSetupError.remoteMaterializerReturnedMismatchedZone(
        expected: remoteZone,
        actual: configuration.remoteZone
      )
    }

    // The callback can suspend while another event materializes the same zone.
    if let existing = storesByRemoteZone[remoteZone] {
      return CloudDataStoreRoute(store: existing)
    }
    let store = try openStoreInternal(configuration)
    return CloudDataStoreRoute(store: store)
  }

  private func handleLocalCommit(
    storeID: CloudDataStoreID,
    metrics: CloudDataStoreMetrics,
    effect: CloudDataStoreCommitEffect
  ) {
    observation.updateStoreMetrics(storeID, metrics: metrics)
    guard effect == .refreshTransport else { return }
    guard
      let coordinator,
      let store = storesByID[storeID]
    else {
      return
    }
    let route = CloudDataStoreRoute(store: store)

    // Consumer policy can commit while a fetched event is still being
    // handled. Never inherit CloudKit's delegate task into an engine call.
    Task.detached {
      await coordinator.localStoreDidCommit(route)
    }
  }

  private static func validate(
    stores: CloudDataStoreDirectory,
    transport: CloudDataTransportConfiguration
  ) throws {
    var storeIDs = Set<CloudDataStoreID>()
    var remoteZones = Set<CloudDataRemoteZone>()
    var storeFileURLs = Set<URL>()
    for store in stores.knownStores {
      try validate(store: store, transport: transport)
      guard storeIDs.insert(store.id).inserted else {
        throw CloudDataStackSetupError.duplicateStoreID(store.id)
      }
      guard remoteZones.insert(store.remoteZone).inserted else {
        throw CloudDataStackSetupError.duplicateRemoteZone(store.remoteZone)
      }
      if case .file(let url) = store.location {
        let normalizedURL = normalizedStoreFileURL(url)
        guard storeFileURLs.insert(normalizedURL).inserted else {
          throw CloudDataStackSetupError.duplicateStoreFileURL(normalizedURL)
        }
      }
    }

    if case .cloudKit(
      let identifier,
      let scopes,
      let subscriptionIDs,
      _
    ) = transport.storage {
      guard identifier.isEmpty == false else {
        throw CloudDataStackSetupError.emptyContainerIdentifier
      }
      guard scopes.isEmpty == false else {
        throw CloudDataStackSetupError.noDatabaseScopes
      }
      for (scope, subscriptionID) in subscriptionIDs {
        guard subscriptionID.rawValue.isEmpty == false else {
          throw CloudDataStackSetupError.emptySubscriptionID(scope: scope)
        }
        guard scopes.contains(scope) else {
          throw CloudDataStackSetupError.subscriptionIDForDisabledScope(
            scope: scope
          )
        }
      }
    }
  }

  private static func validate(
    store: CloudDataStoreConfiguration,
    transport: CloudDataTransportConfiguration
  ) throws {
    guard store.id.rawValue.isEmpty == false else {
      throw CloudDataStackSetupError.emptyStoreID
    }
    guard store.remoteZone.zoneID.zoneName.isEmpty == false else {
      throw CloudDataStackSetupError.emptyZoneName(storeID: store.id)
    }
    if case .named(let ownerName) = store.remoteZone.zoneID.owner,
      ownerName.isEmpty
    {
      throw CloudDataStackSetupError.emptyZoneOwner(storeID: store.id)
    }
    if store.remoteZone.databaseScope == .shared,
      store.remoteZone.zoneID.owner == .currentUser
    {
      throw CloudDataStackSetupError.sharedZoneRequiresNamedOwner(
        storeID: store.id
      )
    }
    if case .cloudKit(_, let scopes, _, _) = transport.storage,
      scopes.contains(store.remoteZone.databaseScope) == false
    {
      throw CloudDataStackSetupError.storeScopeNotEnabled(
        storeID: store.id,
        scope: store.remoteZone.databaseScope
      )
    }
  }

  private static func databaseScopes(
    stores: CloudDataStoreDirectory,
    transport: CloudDataTransportConfiguration
  ) -> Set<CloudDataDatabaseScope> {
    var scopes = Set(stores.knownStores.map { $0.remoteZone.databaseScope })
    if case .cloudKit(_, let configuredScopes, _, _) = transport.storage {
      scopes.formUnion(configuredScopes)
    }
    return scopes
  }

  private static func normalizedStoreFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }
}

extension CloudDataTransportConfiguration {
  fileprivate var isOffline: Bool {
    if case .offline = storage { return true }
    return false
  }
}

struct CloudDataStoreRoute: Sendable {
  let storeID: CloudDataStoreID
  let remoteZone: CloudDataRemoteZone
  let database: CloudDataStoreDatabase

  @MainActor
  init(store: CloudDataStore) {
    self.storeID = store.id
    self.remoteZone = store.configuration.remoteZone
    self.database = store.syncDatabase
  }
}
