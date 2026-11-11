import CloudKit
import CloudKitData
import CloudKitDataConsumerFixture
import CoreLocation
import Foundation
import SwiftData
import Testing

@testable import CloudKitDataStack

private enum AssetFixtureError: Error {
  case missingSource(String)
  case intentionalInstallFailure
}

private enum InstalledAssetValue: Sendable, Equatable {
  case replace(Data)
  case remove
}

private struct InstalledAsset: Sendable, Equatable {
  let reference: CloudDataAssetReference
  let value: InstalledAssetValue
}

private actor AssetFixtureStorage {
  private var sourceDataByIdentifier: [String: Data] = [:]
  private var remainingInstallFailures = 0
  private var installedAssets: [InstalledAsset] = []

  func setSourceData(_ data: Data, for localIdentifier: String) {
    sourceDataByIdentifier[localIdentifier] = data
  }

  func failNextInstalls(_ count: Int) {
    remainingInstallFailures = count
  }

  func materializeOutgoing(
    reference: CloudDataAssetReference,
    destinationURL: URL
  ) throws {
    guard let data = sourceDataByIdentifier[reference.localIdentifier] else {
      throw AssetFixtureError.missingSource(reference.localIdentifier)
    }
    try data.write(to: destinationURL, options: .atomic)
  }

  func installIncoming(
    reference: CloudDataAssetReference,
    action: CloudDataIncomingAssetAction
  ) throws {
    if remainingInstallFailures > 0 {
      remainingInstallFailures -= 1
      throw AssetFixtureError.intentionalInstallFailure
    }

    let value: InstalledAssetValue
    switch action {
    case .replace(let packageFileURL):
      value = .replace(try Data(contentsOf: packageFileURL))
    case .remove:
      value = .remove
    }
    installedAssets.append(InstalledAsset(reference: reference, value: value))
  }

  func installs() -> [InstalledAsset] {
    installedAssets
  }
}

/// Suspends only the first incoming replacement so a test can supersede its
/// durable row while the consumer still reads the old package file.
private actor FirstAssetInstallGate {
  private var hasSuspended = false
  private var suspendedFileURL: URL?
  private var continuation: CheckedContinuation<Void, Never>?

  func suspendFirstReplacement(at fileURL: URL) async {
    guard hasSuspended == false else { return }
    hasSuspended = true
    suspendedFileURL = fileURL
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitForSuspendedFile() async -> URL {
    while true {
      if let suspendedFileURL {
        return suspendedFileURL
      }
      await Task.yield()
    }
  }

  func resume() {
    let continuation = continuation
    self.continuation = nil
    continuation?.resume()
  }
}

/// Captures consumer-facing lifecycle events without exposing transport
/// implementation state to the test.
private actor TransportEventRecorder {
  private var events: [CloudDataTransportEvent] = []

  func append(_ event: CloudDataTransportEvent) {
    events.append(event)
  }

  func snapshot() -> [CloudDataTransportEvent] {
    events
  }
}

private enum TransportDelegateTaskContext {
  @TaskLocal static var isActive = false
}

private struct TransportEventDelivery: Sendable, Equatable {
  let event: CloudDataTransportEvent
  let inheritedDelegateContext: Bool
}

/// Holds the first handler invocation so dispatcher ordering can be asserted
/// without depending on scheduler timing.
private actor SuspendedTransportEventRecorder {
  private var deliveries: [TransportEventDelivery] = []
  private var firstDeliveryWaiters: [CheckedContinuation<Void, Never>] = []
  private var secondDeliveryWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstDeliveryContinuation: CheckedContinuation<Void, Never>?

  func append(_ event: CloudDataTransportEvent) async {
    deliveries.append(
      TransportEventDelivery(
        event: event,
        inheritedDelegateContext: TransportDelegateTaskContext.isActive
      )
    )

    if deliveries.count == 1 {
      let waiters = firstDeliveryWaiters
      firstDeliveryWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        firstDeliveryContinuation = continuation
      }
    }

    if deliveries.count == 2 {
      let waiters = secondDeliveryWaiters
      secondDeliveryWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }
  }

  func waitForFirstDelivery() async {
    guard deliveries.isEmpty else { return }
    await withCheckedContinuation { continuation in
      firstDeliveryWaiters.append(continuation)
    }
  }

  func releaseFirstDelivery() {
    let continuation = firstDeliveryContinuation
    firstDeliveryContinuation = nil
    continuation?.resume()
  }

  func waitForSecondDelivery() async {
    guard deliveries.count < 2 else { return }
    await withCheckedContinuation { continuation in
      secondDeliveryWaiters.append(continuation)
    }
  }

  func snapshot() -> [TransportEventDelivery] {
    deliveries
  }
}

/// Minimal macOS 14-compatible synchronized storage for `@Sendable` test hooks.
private final class TestLockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func update(_ operation: (inout Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    operation(&value)
  }

  func read() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private func makeAssetStore(
  storage: AssetFixtureStorage
) -> CloudDataAssetStore {
  CloudDataAssetStore(
    materializeOutgoing: { reference, destinationURL in
      try await storage.materializeOutgoing(
        reference: reference,
        destinationURL: destinationURL
      )
    },
    installIncoming: { reference, action in
      try await storage.installIncoming(reference: reference, action: action)
    }
  )
}

@Suite(.serialized)
struct CloudKitDataStackTests {
  @Test
  func transportFailuresExposeTheirRecoveryMessage() {
    let summary = CloudDataErrorSummary(
      category: .account,
      operation: "read account status",
      message: "No iCloud account is signed in."
    )
    let failure: any Error = CloudDataTransportOperationError.failed(summary)
    #expect(failure.localizedDescription == summary.message)

    let confirmation: any Error =
      CloudDataTransportOperationError.accountChangeRequiresResolution(
        .signIn(current: .init(rawValue: "account"))
      )
    #expect(
      confirmation.localizedDescription
        == "Confirm this iCloud account before syncing the local library."
    )
  }

  @Test
  func delegateTransportEventsDetachContextAndPreserveFIFO() async {
    let recorder = SuspendedTransportEventRecorder()
    let dispatcher = CloudDataTransportEventDispatcher(
      handler: CloudDataTransportEventHandler { event in
        await recorder.append(event)
      }
    )
    let first = CloudDataTransportEvent.completedFetch(
      databaseScope: .private,
      succeeded: true
    )
    let second = CloudDataTransportEvent.remoteShareChanged(
      .init(databaseScope: .shared, zoneID: .init(zoneName: "shared-zone"))
    )

    await TransportDelegateTaskContext.$isActive.withValue(true) {
      await dispatcher.enqueue(first)
    }
    await recorder.waitForFirstDelivery()

    await TransportDelegateTaskContext.$isActive.withValue(true) {
      await dispatcher.enqueue(second)
    }
    #expect(
      await recorder.snapshot()
        == [
          TransportEventDelivery(
            event: first,
            inheritedDelegateContext: false
          )
        ]
    )

    await recorder.releaseFirstDelivery()
    await recorder.waitForSecondDelivery()
    #expect(
      await recorder.snapshot()
        == [
          TransportEventDelivery(
            event: first,
            inheritedDelegateContext: false
          ),
          TransportEventDelivery(
            event: second,
            inheritedDelegateContext: false
          ),
        ]
    )
  }

  @Test
  @MainActor
  func offlineStackOwnsOneStableReadyStore() async throws {
    let stack = try makeStack(location: .inMemory)
    let storeID = CloudDataStoreID(rawValue: "primary")
    let store = try #require(stack.store(for: storeID))

    #expect(stack.storeIDs == [storeID])
    #expect(stack.store(for: storeID) === store)
    #expect(stack.observation.transportAvailability == .offline)
    #expect(stack.observation.pendingMutationCount == 0)
    guard case .ready = stack.observation.localStores[storeID] else {
      Issue.record("the known local store should be ready")
      return
    }

    await stack.start()
    #expect(stack.observation.transportAvailability == .offline)
  }

  @Test
  @MainActor
  func authoredTransactionCommitsAndCoalescesOutboxWork() throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))
    let card = Card(kind: .text, body: "before", createdAt: .now)

    try store.transaction { transaction in
      try transaction.insert(card)
    }
    #expect(try store.pendingMutationCount() == 1)
    #expect(stack.observation.pendingMutationCount == 1)

    let pending = try store.pendingMutations()
    #expect(pending.count == 1)
    #expect(pending.first?.recordName == card.id.uuidString)
    #expect(pending.first?.recordType == "Card")
    #expect(pending.first?.kind == .save)
    #expect(pending.first?.stagedAt == nil)
    #expect(pending.first?.latestErrorCategory == nil)
    #expect(pending.first?.latestErrorMessage == nil)
    #expect(pending.first?.latestErrorAt == nil)

    try store.transaction { transaction in
      card.body = "after"
      try transaction.synchronize(card)
    }
    #expect(try store.pendingMutationCount() == 1)

    // The save was never staged and has no server metadata, so the insert and
    // delete collapse to no remote operation in the same durable store.
    try store.transaction { transaction in
      try transaction.delete(card)
    }
    #expect(try store.pendingMutationCount() == 0)
    #expect(stack.observation.pendingMutationCount == 0)
    #expect(
      try store.modelContainer.mainContext.fetchCount(FetchDescriptor<Card>()) == 0
    )
  }

  @Test
  @MainActor
  func committedTransactionClassifiesItsTransportEffect() throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))
    let card = Card(kind: .text, body: "before", createdAt: .now)

    try store.transaction { transaction in
      try transaction.insert(card)
    }

    var effects: [CloudDataStoreCommitEffect] = []
    store.setCommitHandler { _, _, effect in
      effects.append(effect)
    }

    // Incoming asset installation uses a fresh context for local presentation
    // state. It must not wake CKSyncEngine from inside a delegate event.
    try store.transactionWithFreshContext { transaction in
      let storedCard = try #require(
        transaction.modelContext.fetch(FetchDescriptor<Card>()).first
      )
      storedCard.localDraft = "installed locally"
    }
    #expect(effects == [.localOnly])

    try store.transaction { transaction in
      card.body = "after"
      try transaction.synchronize(card)
    }
    #expect(effects == [.localOnly, .refreshTransport])

    // Cancelling a previously committed but never-staged insert still refreshes
    // the engine because it may already hold that pending record identifier.
    let cancelledCard = Card(kind: .text, body: "cancelled", createdAt: .now)
    try store.transaction { transaction in
      try transaction.insert(cancelledCard)
    }
    try store.transaction { transaction in
      try transaction.delete(cancelledCard)
    }
    #expect(
      effects
        == [
          .localOnly,
          .refreshTransport,
          .refreshTransport,
          .refreshTransport,
        ]
    )
  }

  @Test
  @MainActor
  func authoredDeleteRejectsAnEmptyRecordName() throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))
    let model = StringIdentityModel(recordName: "", value: "invalid")

    #expect(
      throws: CloudDataTransactionError.emptyRecordName(
        recordType: "StringIdentity"
      )
    ) {
      try store.transaction { transaction in
        try transaction.delete(model)
      }
    }
    #expect(try store.pendingMutationCount() == 0)
  }

  @Test
  @MainActor
  func authoredTransactionRejectsNestedCommits() throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))

    #expect(throws: CloudDataTransactionError.nestedTransaction) {
      try store.transaction { _ in
        try store.transaction { _ in }
      }
    }
    #expect(try store.pendingMutationCount() == 0)
  }

  @Test
  @MainActor
  func fileStoreRecoversDurableOutboxAcrossStackRestart() async throws {
    let rootURL = temporaryDirectoryURL()
    let recordID = UUID()

    do {
      let stack = try makeStack(
        location: .file(rootURL.appendingPathComponent("content.store")),
        rootURL: rootURL
      )
      let store = try #require(stack.store(for: .init(rawValue: "primary")))
      try store.transaction { transaction in
        try transaction.insert(
          Card(
            id: recordID,
            kind: .todo,
            body: "survives",
            createdAt: .now
          )
        )
      }
      #expect(try store.pendingMutationCount() == 1)
    }

    do {
      let stack = try makeStack(
        location: .file(rootURL.appendingPathComponent("content.store")),
        rootURL: rootURL
      )
      let store = try #require(stack.store(for: .init(rawValue: "primary")))
      #expect(stack.observation.pendingMutationCount == 1)
      #expect(try store.pendingMutationCount() == 1)

      let reseeded = try await store.syncDatabase.pendingChanges(
        resetStaging: true
      )
      #expect(reseeded.count == 1)
      #expect(reseeded.first?.recordName == recordID.uuidString)

      let fetched =
        try Card.cloudModelRegistration.fetch(
          recordName: recordID.uuidString,
          in: store.modelContainer.mainContext
        ) as? Card
      #expect(fetched?.body == "survives")
    }

    try FileManager.default.removeItem(at: rootURL)
  }

  @Test
  @MainActor
  func localStoreOpenFailureRecoveryCanRepairAndRetryOnce() throws {
    let rootURL = temporaryDirectoryURL()
    let storeURL = rootURL.appendingPathComponent("content.store")
    let engineStateDirectoryURL = rootURL.appendingPathComponent("engine-state")
    let privateStateURL = engineStateDirectoryURL.appendingPathComponent(
      "cksyncengine-private.json"
    )
    let sharedStateURL = engineStateDirectoryURL.appendingPathComponent(
      "cksyncengine-shared.json"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: engineStateDirectoryURL,
      withIntermediateDirectories: true
    )
    try Data([0x00, 0x01, 0x02]).write(to: storeURL)
    try Data([0x03]).write(to: privateStateURL)
    try Data([0x04]).write(to: sharedStateURL)

    let recoveryCount = TestLockedBox(0)
    let recoveredError = TestLockedBox<CloudDataStackSetupError?>(nil)
    let configuration = CloudDataStoreConfiguration(
      id: .init(rawValue: "recoverable"),
      location: .file(storeURL),
      remoteZone: .init(
        databaseScope: .private,
        zoneID: .init(zoneName: "recoverable-zone")
      )
    )
    let stack = try CloudKitDataStack(
      schema: CloudDataSchema(models: [Card.self]),
      stores: CloudDataStoreDirectory(
        knownStores: [configuration],
        engineStateDirectoryURL: engineStateDirectoryURL,
        recoverLocalStoreOpenFailure: { failedConfiguration, error in
          recoveryCount.update { $0 += 1 }
          recoveredError.update { $0 = error }
          guard failedConfiguration == configuration else { return .decline }
          try FileManager.default.removeItem(at: storeURL)
          return .retryAndInvalidateTransportState
        }
      ),
      transport: .cloudKit(
        containerIdentifier: "iCloud.example.RecoveryFixture",
        databaseScopes: [.private],
        automaticallySync: false
      )
    )

    #expect(stack.store(for: configuration.id) != nil)
    #expect(recoveryCount.read() == 1)
    #expect(FileManager.default.fileExists(atPath: privateStateURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: sharedStateURL.path) == false)
    guard
      case .localStoreOpenFailed(let failedStoreID, _) = recoveredError.read()
    else {
      Issue.record("the recovery hook should receive the local open failure")
      return
    }
    #expect(failedStoreID == configuration.id)
  }

  @Test
  @MainActor
  func localStoreOpenFailureRecoveryNeverLoops() throws {
    let rootURL = temporaryDirectoryURL()
    let storeURL = rootURL.appendingPathComponent("content.store")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    try Data([0x00, 0x01, 0x02]).write(to: storeURL)

    let recoveryCount = TestLockedBox(0)
    let configuration = CloudDataStoreConfiguration(
      id: .init(rawValue: "still-broken"),
      location: .file(storeURL),
      remoteZone: .init(
        databaseScope: .private,
        zoneID: .init(zoneName: "still-broken-zone")
      )
    )

    do {
      _ = try CloudKitDataStack(
        schema: CloudDataSchema(models: [Card.self]),
        stores: CloudDataStoreDirectory(
          knownStores: [configuration],
          engineStateDirectoryURL: rootURL.appendingPathComponent("engine-state"),
          recoverLocalStoreOpenFailure: { _, _ in
            recoveryCount.update { $0 += 1 }
            return .retry
          }
        ),
        transport: .offline
      )
      Issue.record("an ineffective recovery should still surface the open failure")
    } catch let error as CloudDataStackSetupError {
      guard case .localStoreOpenFailed(let failedStoreID, _) = error else {
        Issue.record("the retry should preserve the local open failure category")
        return
      }
      #expect(failedStoreID == configuration.id)
    }

    #expect(recoveryCount.read() == 1)
  }

  @Test
  @MainActor
  func stableMainContextsRefreshBeforeCrossContainerTransactions() throws {
    let rootURL = temporaryDirectoryURL()
    let storeURL = rootURL.appendingPathComponent("content.store")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let firstStack = try makeStack(location: .file(storeURL), rootURL: rootURL)
    let secondStack = try makeStack(location: .file(storeURL), rootURL: rootURL)
    let storeID = CloudDataStoreID(rawValue: "primary")
    let firstStore = try #require(firstStack.store(for: storeID))
    let secondStore = try #require(secondStack.store(for: storeID))

    // Warm the second stable context before another container commits.
    #expect(
      try secondStore.modelContainer.mainContext.fetchCount(FetchDescriptor<Card>()) == 0
    )

    let cardID = UUID()
    try firstStore.transaction { transaction in
      try transaction.insert(
        Card(id: cardID, kind: .text, body: "first", createdAt: .now)
      )
    }

    let bodySeenBySecond = try secondStore.transaction { transaction in
      let card = try #require(
        try transaction.modelContext.fetch(FetchDescriptor<Card>()).first {
          $0.id == cardID
        }
      )
      card.body = "second"
      try transaction.synchronize(card)
      return card.body
    }
    #expect(bodySeenBySecond == "second")

    let bodySeenByFirst = try firstStore.transaction { transaction in
      try #require(
        transaction.modelContext.fetch(FetchDescriptor<Card>()).first {
          $0.id == cardID
        }
      ).body
    }
    #expect(bodySeenByFirst == "second")
  }

  @Test
  @MainActor
  func acknowledgementDoesNotConsumeAReenqueuedRevision() async throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))
    let card = Card(kind: .text, body: "first", createdAt: .now)
    try store.transaction { transaction in
      try transaction.insert(card)
    }

    let database = store.syncDatabase
    let firstOutgoing = try #require(
      try await database.prepareOutgoingSave(recordName: card.id.uuidString)
    )
    #expect(try await database.metrics().stagedCount == 1)

    try store.transaction { transaction in
      card.body = "second"
      try transaction.synchronize(card)
    }
    #expect(try await database.metrics().stagedCount == 0)

    let recordID = cloudRecordID(recordName: card.id.uuidString)
    let firstAcknowledgement = try CloudKitRecordAdapter.makeRecord(
      from: firstOutgoing,
      descriptor: Card.cloudModelRegistration.descriptor,
      recordID: recordID
    )
    let afterStaleAcknowledgement = try await database.acknowledgeSavedRecord(
      recordType: "Card",
      recordName: card.id.uuidString,
      stagedRevision: firstOutgoing.revision,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(
        of: firstAcknowledgement
      )
    )
    #expect(afterStaleAcknowledgement.pendingCount == 1)

    let secondOutgoing = try #require(
      try await database.prepareOutgoingSave(recordName: card.id.uuidString)
    )
    #expect(secondOutgoing.snapshot.fields["body"] == .string("second"))
    let secondAcknowledgement = try CloudKitRecordAdapter.makeRecord(
      from: secondOutgoing,
      descriptor: Card.cloudModelRegistration.descriptor,
      recordID: recordID
    )
    let finalMetrics = try await database.acknowledgeSavedRecord(
      recordType: "Card",
      recordName: card.id.uuidString,
      stagedRevision: secondOutgoing.revision,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(
        of: secondAcknowledgement
      )
    )
    #expect(finalMetrics.pendingCount == 0)
  }

  @Test
  @MainActor
  func saveAcknowledgementDoesNotConsumeANewerDelete() async throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))
    let card = Card(kind: .text, body: "delete me", createdAt: .now)
    try store.transaction { transaction in
      try transaction.insert(card)
    }

    let database = store.syncDatabase
    let outgoingSave = try #require(
      try await database.prepareOutgoingSave(recordName: card.id.uuidString)
    )
    try store.transaction { transaction in
      try transaction.delete(card)
    }

    let pendingAfterDelete = try await database.pendingChanges(
      resetStaging: false
    )
    #expect(pendingAfterDelete.count == 1)
    #expect(pendingAfterDelete.first?.kind == .delete)

    let acknowledgement = try CloudKitRecordAdapter.makeRecord(
      from: outgoingSave,
      descriptor: Card.cloudModelRegistration.descriptor,
      recordID: cloudRecordID(recordName: card.id.uuidString)
    )
    let metrics = try await database.acknowledgeSavedRecord(
      recordType: "Card",
      recordName: card.id.uuidString,
      stagedRevision: outgoingSave.revision,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(
        of: acknowledgement
      )
    )
    #expect(metrics.pendingCount == 1)
    #expect(
      try await database.pendingChanges(resetStaging: false).first?.kind
        == .delete
    )

    let deleteRevision = try #require(
      try await database.stageDelete(recordName: card.id.uuidString)
    )
    let finalMetrics = try await database.acknowledgeDeletedRecord(
      recordName: card.id.uuidString,
      stagedRevision: deleteRevision
    )
    #expect(finalMetrics.pendingCount == 0)
  }

  @Test
  @MainActor
  func remoteImportMaterializesAndMergesWithoutOutboxEcho() async throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))
    let card = Card(kind: .todo, body: "remote", createdAt: .now)
    let registration = Card.cloudModelRegistration
    let firstSnapshot = try registration.makeSnapshot(from: card)
    let record = CKRecord(
      recordType: "Card",
      recordID: cloudRecordID(recordName: card.id.uuidString)
    )

    let firstOutcome = try await store.syncDatabase.applyRemoteSave(
      recordType: "Card",
      snapshot: firstSnapshot,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: record)
    )
    #expect(firstOutcome == .inserted)
    #expect(try await store.syncDatabase.metrics().pendingCount == 0)

    var changedFields = firstSnapshot.fields
    changedFields["body"] = .string("merged")
    let secondOutcome = try await store.syncDatabase.applyRemoteSave(
      recordType: "Card",
      snapshot: CloudRecordSnapshot(
        recordName: firstSnapshot.recordName,
        fields: changedFields
      ),
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: record)
    )
    #expect(secondOutcome == .merged)
    #expect(try await store.syncDatabase.metrics().pendingCount == 0)

    let verificationContext = ModelContext(store.modelContainer)
    let fetched =
      try registration.fetch(
        recordName: card.id.uuidString,
        in: verificationContext
      ) as? Card
    #expect(fetched?.body == "merged")
  }

  @Test
  @MainActor
  func remoteImportRepairsAnOutOfOrderRelationshipWhenTheTargetArrives() async throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))
    let card = Card(kind: .text, body: "target", createdAt: .now)
    let edge = CardEdge(cardRecordName: card.id.uuidString)
    let edgeSnapshot = try CardEdge.cloudModelRegistration.makeSnapshot(from: edge)
    let edgeRecord = CKRecord(
      recordType: "CardEdge",
      recordID: cloudRecordID(recordName: edge.id.uuidString)
    )

    let edgeOutcome = try await store.syncDatabase.applyRemoteSave(
      recordType: "CardEdge",
      snapshot: edgeSnapshot,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: edgeRecord)
    )
    #expect(edgeOutcome == .inserted)
    #expect(try await store.syncDatabase.unresolvedRelationshipCount() == 1)

    let cardSnapshot = try Card.cloudModelRegistration.makeSnapshot(from: card)
    let cardRecord = CKRecord(
      recordType: "Card",
      recordID: cloudRecordID(recordName: card.id.uuidString)
    )
    let cardOutcome = try await store.syncDatabase.applyRemoteSave(
      recordType: "Card",
      snapshot: cardSnapshot,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: cardRecord)
    )
    #expect(cardOutcome == .inserted)
    #expect(try await store.syncDatabase.unresolvedRelationshipCount() == 0)

    let verificationContext = ModelContext(store.modelContainer)
    let fetchedEdge = try #require(
      try CardEdge.cloudModelRegistration.fetch(
        recordName: edge.id.uuidString,
        in: verificationContext
      ) as? CardEdge
    )
    #expect(fetchedEdge.card?.id == card.id)
  }

  @Test
  @MainActor
  func relationshipRepairStaysWithinTheExactStoreRoute() async throws {
    let rootURL = temporaryDirectoryURL()
    let schema = try CloudDataSchema(
      models: [Card.self, CardEdge.self]
    )
    let primaryConfiguration = CloudDataStoreConfiguration(
      id: .init(rawValue: "primary"),
      location: .inMemory,
      remoteZone: .init(
        databaseScope: .private,
        zoneID: .init(zoneName: "primary-zone")
      )
    )
    let secondaryConfiguration = CloudDataStoreConfiguration(
      id: .init(rawValue: "secondary"),
      location: .inMemory,
      remoteZone: .init(
        databaseScope: .private,
        zoneID: .init(zoneName: "secondary-zone")
      )
    )
    let stack = try CloudKitDataStack(
      schema: schema,
      stores: .init(
        knownStores: [primaryConfiguration, secondaryConfiguration],
        engineStateDirectoryURL: rootURL.appendingPathComponent("engine-state")
      ),
      transport: .offline
    )
    let primary = try #require(stack.store(for: primaryConfiguration.id))
    let secondary = try #require(stack.store(for: secondaryConfiguration.id))
    let card = Card(kind: .text, body: "target", createdAt: .now)
    let edge = CardEdge(cardRecordName: card.id.uuidString)

    let edgeRecord = CKRecord(
      recordType: "CardEdge",
      recordID: cloudRecordID(
        recordName: edge.id.uuidString,
        zoneName: "primary-zone"
      )
    )
    _ = try await primary.syncDatabase.applyRemoteSave(
      recordType: "CardEdge",
      snapshot: CardEdge.cloudModelRegistration.makeSnapshot(from: edge),
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: edgeRecord)
    )

    let secondaryCardRecord = CKRecord(
      recordType: "Card",
      recordID: cloudRecordID(
        recordName: card.id.uuidString,
        zoneName: "secondary-zone"
      )
    )
    _ = try await secondary.syncDatabase.applyRemoteSave(
      recordType: "Card",
      snapshot: Card.cloudModelRegistration.makeSnapshot(from: card),
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: secondaryCardRecord)
    )
    await stack.rescanPendingChanges()
    #expect(try await primary.syncDatabase.unresolvedRelationshipCount() == 1)

    let primaryCardRecord = CKRecord(
      recordType: "Card",
      recordID: cloudRecordID(
        recordName: card.id.uuidString,
        zoneName: "primary-zone"
      )
    )
    _ = try await primary.syncDatabase.applyRemoteSave(
      recordType: "Card",
      snapshot: Card.cloudModelRegistration.makeSnapshot(from: card),
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: primaryCardRecord)
    )
    #expect(try await primary.syncDatabase.unresolvedRelationshipCount() == 0)
  }

  @Test
  @MainActor
  func startupRepairsDurableRelationshipWork() async throws {
    let rootURL = temporaryDirectoryURL()
    let storeURL = rootURL.appendingPathComponent("content.store")
    let cardID = UUID()
    let edgeID = UUID()

    do {
      let stack = try makeStack(location: .file(storeURL), rootURL: rootURL)
      let store = try #require(stack.store(for: .init(rawValue: "primary")))
      let card = Card(
        id: cardID,
        kind: .text,
        body: "local target",
        createdAt: .now
      )
      let edge = CardEdge(
        id: edgeID,
        cardRecordName: cardID.uuidString
      )
      let edgeRecord = CKRecord(
        recordType: "CardEdge",
        recordID: cloudRecordID(recordName: edgeID.uuidString)
      )
      _ = try await store.syncDatabase.applyRemoteSave(
        recordType: "CardEdge",
        snapshot: CardEdge.cloudModelRegistration.makeSnapshot(from: edge),
        systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: edgeRecord)
      )
      try store.transaction { transaction in
        try transaction.insert(card)
      }
      #expect(try await store.syncDatabase.unresolvedRelationshipCount() == 1)
    }

    do {
      let stack = try makeStack(location: .file(storeURL), rootURL: rootURL)
      let store = try #require(stack.store(for: .init(rawValue: "primary")))
      #expect(try await store.syncDatabase.unresolvedRelationshipCount() == 1)
      await stack.start()
      #expect(try await store.syncDatabase.unresolvedRelationshipCount() == 0)

      let verificationContext = ModelContext(store.modelContainer)
      let fetchedEdge = try #require(
        try CardEdge.cloudModelRegistration.fetch(
          recordName: edgeID.uuidString,
          in: verificationContext
        ) as? CardEdge
      )
      #expect(fetchedEdge.card?.id == cardID)
    }

    try FileManager.default.removeItem(at: rootURL)
  }

  @Test
  @MainActor
  func remoteDeletionRemovesStaleUnresolvedRelationshipWork() async throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))
    let targetID = UUID()
    let edge = CardEdge(cardRecordName: targetID.uuidString)
    let edgeRecord = CKRecord(
      recordType: "CardEdge",
      recordID: cloudRecordID(recordName: edge.id.uuidString)
    )
    _ = try await store.syncDatabase.applyRemoteSave(
      recordType: "CardEdge",
      snapshot: CardEdge.cloudModelRegistration.makeSnapshot(from: edge),
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: edgeRecord)
    )
    #expect(try await store.syncDatabase.unresolvedRelationshipCount() == 1)

    let outcome = try await store.syncDatabase.applyRemoteDelete(
      recordType: "Card",
      recordName: targetID.uuidString
    )
    #expect(outcome == .absent)
    #expect(try await store.syncDatabase.unresolvedRelationshipCount() == 0)

    let sourceDeletedEdge = CardEdge(cardRecordName: UUID().uuidString)
    let sourceDeletedRecord = CKRecord(
      recordType: "CardEdge",
      recordID: cloudRecordID(recordName: sourceDeletedEdge.id.uuidString)
    )
    _ = try await store.syncDatabase.applyRemoteSave(
      recordType: "CardEdge",
      snapshot: CardEdge.cloudModelRegistration.makeSnapshot(from: sourceDeletedEdge),
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: sourceDeletedRecord)
    )
    #expect(try await store.syncDatabase.unresolvedRelationshipCount() == 1)

    let sourceOutcome = try await store.syncDatabase.applyRemoteDelete(
      recordType: "CardEdge",
      recordName: sourceDeletedEdge.id.uuidString
    )
    #expect(sourceOutcome == .merged)
    #expect(try await store.syncDatabase.unresolvedRelationshipCount() == 0)
  }

  @Test
  @MainActor
  func remoteImportRejectsAPendingRecordTypeCollision() async throws {
    let stack = try makeStack(location: .inMemory)
    let store = try #require(stack.store(for: .init(rawValue: "primary")))
    let card = Card(kind: .text, body: "local", createdAt: .now)
    try store.transaction { transaction in
      try transaction.insert(card)
    }
    let recordName = card.id.uuidString
    let remoteModel = StringIdentityModel(
      recordName: recordName,
      value: "remote"
    )
    let snapshot = try StringIdentityModel.cloudModelRegistration.makeSnapshot(
      from: remoteModel
    )
    let record = CKRecord(
      recordType: "StringIdentity",
      recordID: cloudRecordID(recordName: recordName)
    )

    do {
      _ = try await store.syncDatabase.applyRemoteSave(
        recordType: "StringIdentity",
        snapshot: snapshot,
        systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: record)
      )
      Issue.record("a zone-wide record-name collision should be rejected")
    } catch let error as CloudDataStoreRuntimeError {
      #expect(
        error
          == .recordNameCollision(
            recordName: recordName,
            existingRecordType: "Card",
            requestedRecordType: "StringIdentity"
          )
      )
    }
    #expect(try await store.syncDatabase.metrics().pendingCount == 1)
  }

  @Test
  @MainActor
  func outgoingAssetsStageMultipleSlotsAndUseExactAcknowledgement() async throws {
    let rootURL = temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storage = AssetFixtureStorage()
    let stack = try makeAssetStack(
      location: .inMemory,
      rootURL: rootURL,
      assetStore: makeAssetStore(storage: storage)
    )
    let store = try #require(
      stack.store(for: .init(rawValue: "asset-primary"))
    )
    let resource = AttachmentResource(mediaType: "image/jpeg")
    let fileData = Data("full".utf8)
    let thumbnailData = Data("thumb".utf8)
    await storage.setSourceData(
      fileData,
      for: resource.fileAsset.localIdentifier
    )
    await storage.setSourceData(
      thumbnailData,
      for: resource.thumbnailAsset.localIdentifier
    )

    let file = try await store.prepareAssetReplacement(
      for: resource,
      at: \AttachmentResource.fileAsset
    )
    let thumbnail = try await store.prepareAssetReplacement(
      for: resource,
      at: \AttachmentResource.thumbnailAsset
    )
    try store.transaction { transaction in
      try transaction.insert(resource)
      try transaction.replaceAsset(
        resource,
        at: \AttachmentResource.fileAsset,
        with: file
      )
      try transaction.replaceAsset(
        resource,
        at: \AttachmentResource.thumbnailAsset,
        with: thumbnail
      )
    }
    #expect(stack.observation.pendingAssetTransferCount == 2)

    let database = store.syncDatabase
    let firstOutgoing = try #require(
      try await database.prepareOutgoingSave(
        recordName: resource.id.uuidString
      )
    )
    #expect(firstOutgoing.assets.count == 2)
    #expect(try await database.pendingAssetMutationCount() == 2)
    #expect(try await database.stagedAssetFileCount() == 2)

    let firstRecord = try CloudKitRecordAdapter.makeRecord(
      from: firstOutgoing,
      descriptor: AttachmentResource.cloudModelRegistration.descriptor,
      recordID: cloudRecordID(
        recordName: resource.id.uuidString,
        zoneName: "asset-fixture-zone"
      )
    )
    let recordFile = try #require(firstRecord["file"] as? CKAsset)
    let recordThumbnail = try #require(firstRecord["thumbnail"] as? CKAsset)
    let stagedRecordFileURL = try #require(recordFile.fileURL)
    let stagedRecordThumbnailURL = try #require(recordThumbnail.fileURL)
    #expect(try Data(contentsOf: stagedRecordFileURL) == fileData)
    #expect(
      try Data(contentsOf: stagedRecordThumbnailURL) == thumbnailData
    )

    try store.transaction { transaction in
      resource.mediaType = "image/heic"
      try transaction.synchronize(resource)
    }
    let staleMetrics = try await database.acknowledgeSavedRecord(
      recordType: "AttachmentResource",
      recordName: resource.id.uuidString,
      stagedRevision: firstOutgoing.revision,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: firstRecord)
    )
    #expect(staleMetrics.pendingCount == 1)
    #expect(try await database.pendingAssetMutationCount() == 2)
    #expect(try await database.stagedAssetFileCount() == 2)
    #expect(FileManager.default.fileExists(atPath: stagedRecordFileURL.path))

    let secondOutgoing = try #require(
      try await database.prepareOutgoingSave(
        recordName: resource.id.uuidString
      )
    )
    #expect(secondOutgoing.revision != firstOutgoing.revision)
    #expect(secondOutgoing.assets.count == 2)
    let secondRecord = try CloudKitRecordAdapter.makeRecord(
      from: secondOutgoing,
      descriptor: AttachmentResource.cloudModelRegistration.descriptor,
      recordID: firstRecord.recordID
    )
    let finalMetrics = try await database.acknowledgeSavedRecord(
      recordType: "AttachmentResource",
      recordName: resource.id.uuidString,
      stagedRevision: secondOutgoing.revision,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: secondRecord)
    )
    #expect(finalMetrics.pendingCount == 0)
    #expect(try await database.pendingAssetMutationCount() == 0)
    #expect(try await database.stagedAssetFileCount() == 0)
    #expect(FileManager.default.fileExists(atPath: stagedRecordFileURL.path) == false)
  }

  @Test
  @MainActor
  func assetPreserveAndRemoveAreExplicitPerField() async throws {
    let rootURL = temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storage = AssetFixtureStorage()
    let stack = try makeAssetStack(
      location: .inMemory,
      rootURL: rootURL,
      assetStore: makeAssetStore(storage: storage)
    )
    let store = try #require(
      stack.store(for: .init(rawValue: "asset-primary"))
    )
    let resource = AttachmentResource(mediaType: "image/jpeg")

    try store.transaction { transaction in
      try transaction.insert(resource)
      try transaction.removeAsset(
        resource,
        at: \AttachmentResource.fileAsset
      )
      try transaction.preserveAsset(
        resource,
        at: \AttachmentResource.thumbnailAsset
      )
    }
    let outgoing = try #require(
      try await store.syncDatabase.prepareOutgoingSave(
        recordName: resource.id.uuidString
      )
    )
    #expect(outgoing.assets.count == 1)
    #expect(outgoing.assets.first?.fieldKey == "file")
    #expect(outgoing.assets.first?.kind == .remove)

    let record = try CloudKitRecordAdapter.makeRecord(
      from: outgoing,
      descriptor: AttachmentResource.cloudModelRegistration.descriptor,
      recordID: cloudRecordID(
        recordName: resource.id.uuidString,
        zoneName: "asset-fixture-zone"
      )
    )
    #expect(record.changedKeys().contains("file"))
    #expect(record.changedKeys().contains("thumbnail") == false)
    #expect(record["file"] == nil)
  }

  @Test
  @MainActor
  func incomingAssetsAreCapturedAndInstalledBeforeImportCompletes() async throws {
    let rootURL = temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storage = AssetFixtureStorage()
    let stack = try makeAssetStack(
      location: .inMemory,
      rootURL: rootURL,
      assetStore: makeAssetStore(storage: storage)
    )
    let store = try #require(
      stack.store(for: .init(rawValue: "asset-primary"))
    )
    let resource = AttachmentResource(mediaType: "image/png")
    let sourceURL = rootURL.appendingPathComponent("system-file")
    let sourceData = Data("incoming".utf8)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    try sourceData.write(to: sourceURL)

    let record = try CloudKitRecordAdapter.makeRecord(
      from: .init(
        recordType: "AttachmentResource",
        snapshot: try AttachmentResource.cloudModelRegistration.makeSnapshot(
          from: resource
        ),
        systemFieldsData: nil
      ),
      descriptor: AttachmentResource.cloudModelRegistration.descriptor,
      recordID: cloudRecordID(
        recordName: resource.id.uuidString,
        zoneName: "asset-fixture-zone"
      )
    )
    record["file"] = CKAsset(fileURL: sourceURL)
    let decoded = try CloudKitRecordAdapter.decodedRecord(
      from: record,
      descriptor: AttachmentResource.cloudModelRegistration.descriptor
    )
    _ = try await store.syncDatabase.applyRemoteSave(
      recordType: record.recordType,
      snapshot: decoded.snapshot,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: record),
      assets: decoded.assets
    )

    #expect(try await store.syncDatabase.pendingAssetInstallCount() == 0)
    #expect(try await store.syncDatabase.stagedAssetFileCount() == 0)
    let installs = await storage.installs()
    #expect(installs.count == 2)
    #expect(
      installs.contains(
        InstalledAsset(
          reference: .init(
            storeID: .init(rawValue: "asset-primary"),
            recordType: "AttachmentResource",
            recordName: resource.id.uuidString,
            fieldKey: "file",
            localIdentifier: resource.fileAsset.localIdentifier
          ),
          value: .replace(sourceData)
        )
      )
    )
    #expect(
      installs.contains(where: { $0.reference.fieldKey == "thumbnail" && $0.value == .remove }))

    record["file"] = "wrong"
    #expect(throws: CloudKitRecordAdapterError.invalidAssetField("file")) {
      try CloudKitRecordAdapter.decodedRecord(
        from: record,
        descriptor: AttachmentResource.cloudModelRegistration.descriptor
      )
    }
  }

  @Test
  @MainActor
  func failedIncomingInstallReplaysFromPackageStagingAfterRestart() async throws {
    let rootURL = temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("asset.sqlite")
    let storage = AssetFixtureStorage()
    await storage.failNextInstalls(1)
    let resource = AttachmentResource(mediaType: "application/octet-stream")
    let sourceURL = rootURL.appendingPathComponent("ephemeral-system-file")
    let sourceData = Data("restart-safe".utf8)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    try sourceData.write(to: sourceURL)
    let record = try CloudKitRecordAdapter.makeRecord(
      from: .init(
        recordType: "AttachmentResource",
        snapshot: try AttachmentResource.cloudModelRegistration.makeSnapshot(
          from: resource
        ),
        systemFieldsData: nil
      ),
      descriptor: AttachmentResource.cloudModelRegistration.descriptor,
      recordID: cloudRecordID(
        recordName: resource.id.uuidString,
        zoneName: "asset-fixture-zone"
      )
    )
    record["file"] = CKAsset(fileURL: sourceURL)
    let decoded = try CloudKitRecordAdapter.decodedRecord(
      from: record,
      descriptor: AttachmentResource.cloudModelRegistration.descriptor
    )

    do {
      let stack = try makeAssetStack(
        location: .file(storeURL),
        rootURL: rootURL,
        assetStore: makeAssetStore(storage: storage)
      )
      let store = try #require(
        stack.store(for: .init(rawValue: "asset-primary"))
      )
      do {
        _ = try await store.syncDatabase.applyRemoteSave(
          recordType: record.recordType,
          snapshot: decoded.snapshot,
          systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: record),
          assets: decoded.assets
        )
        Issue.record("the first consumer install should fail")
      } catch AssetFixtureError.intentionalInstallFailure {
        // The durable queue and package copy must remain for restart replay.
      }
      #expect(try await store.syncDatabase.pendingAssetInstallCount() == 2)
      #expect(try await store.syncDatabase.stagedAssetFileCount() == 1)
    }

    try FileManager.default.removeItem(at: sourceURL)

    do {
      let stack = try makeAssetStack(
        location: .file(storeURL),
        rootURL: rootURL,
        assetStore: makeAssetStore(storage: storage)
      )
      #expect(stack.observation.pendingAssetTransferCount == 2)
      await stack.start()
      #expect(stack.observation.pendingAssetTransferCount == 0)
      let store = try #require(
        stack.store(for: .init(rawValue: "asset-primary"))
      )
      #expect(try await store.syncDatabase.pendingAssetInstallCount() == 0)
      #expect(try await store.syncDatabase.stagedAssetFileCount() == 0)
      let installs = await storage.installs()
      #expect(installs.contains(where: { $0.value == .replace(sourceData) }))
      #expect(installs.contains(where: { $0.value == .remove }))
    }
  }

  @Test
  @MainActor
  func remoteDeleteDurablyRemovesAssetsAndCleansPackageStaging() async throws {
    let rootURL = temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storage = AssetFixtureStorage()
    await storage.failNextInstalls(2)
    let stack = try makeAssetStack(
      location: .inMemory,
      rootURL: rootURL,
      assetStore: makeAssetStore(storage: storage)
    )
    let store = try #require(
      stack.store(for: .init(rawValue: "asset-primary"))
    )
    let resource = AttachmentResource(mediaType: "image/heic")
    let sourceURL = rootURL.appendingPathComponent("remote-delete-source")
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    try Data("delete-me".utf8).write(to: sourceURL)

    let record = try CloudKitRecordAdapter.makeRecord(
      from: .init(
        recordType: "AttachmentResource",
        snapshot: try AttachmentResource.cloudModelRegistration.makeSnapshot(
          from: resource
        ),
        systemFieldsData: nil
      ),
      descriptor: AttachmentResource.cloudModelRegistration.descriptor,
      recordID: cloudRecordID(
        recordName: resource.id.uuidString,
        zoneName: "asset-fixture-zone"
      )
    )
    record["file"] = CKAsset(fileURL: sourceURL)
    let decoded = try CloudKitRecordAdapter.decodedRecord(
      from: record,
      descriptor: AttachmentResource.cloudModelRegistration.descriptor
    )

    do {
      _ = try await store.syncDatabase.applyRemoteSave(
        recordType: record.recordType,
        snapshot: decoded.snapshot,
        systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: record),
        assets: decoded.assets
      )
      Issue.record("the first consumer install should fail")
    } catch AssetFixtureError.intentionalInstallFailure {
      // The tombstone below must supersede and clean this durable replacement.
    }
    #expect(try await store.syncDatabase.pendingAssetInstallCount() == 2)
    #expect(try await store.syncDatabase.stagedAssetFileCount() == 1)

    do {
      _ = try await store.syncDatabase.applyRemoteDelete(
        recordType: record.recordType,
        recordName: resource.id.uuidString
      )
      Issue.record("the first consumer removal should fail")
    } catch AssetFixtureError.intentionalInstallFailure {
      // The model is gone, but both logical removals must stay durable.
    }
    #expect(try await store.syncDatabase.pendingAssetInstallCount() == 2)
    #expect(try await store.syncDatabase.stagedAssetFileCount() == 0)

    let outcome = try await store.syncDatabase.applyRemoteDelete(
      recordType: record.recordType,
      recordName: resource.id.uuidString
    )
    #expect(outcome == .absent)
    #expect(try await store.syncDatabase.pendingAssetInstallCount() == 0)
    #expect(try await store.syncDatabase.stagedAssetFileCount() == 0)
    let installs = await storage.installs()
    #expect(installs.count == 2)
    #expect(installs.allSatisfy { $0.value == .remove })

    let resourceID = resource.id
    let descriptor = FetchDescriptor<AttachmentResource>(
      predicate: #Predicate { $0.id == resourceID }
    )
    #expect(try store.modelContainer.mainContext.fetch(descriptor).isEmpty)
  }

  @Test
  @MainActor
  func supersededIncomingAssetKeepsItsPackageFileUntilInstallerReturns() async throws {
    let rootURL = temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storage = AssetFixtureStorage()
    let gate = FirstAssetInstallGate()
    let assetStore = CloudDataAssetStore(
      materializeOutgoing: { reference, destinationURL in
        try await storage.materializeOutgoing(
          reference: reference,
          destinationURL: destinationURL
        )
      },
      installIncoming: { reference, action in
        if case .replace(let packageFileURL) = action,
          reference.fieldKey == "file"
        {
          await gate.suspendFirstReplacement(at: packageFileURL)
        }
        try await storage.installIncoming(reference: reference, action: action)
      }
    )
    let stack = try makeAssetStack(
      location: .inMemory,
      rootURL: rootURL,
      assetStore: assetStore
    )
    let store = try #require(
      stack.store(for: .init(rawValue: "asset-primary"))
    )
    let resource = AttachmentResource(mediaType: "image/heic")
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    let firstSourceURL = rootURL.appendingPathComponent("first-system-file")
    let secondSourceURL = rootURL.appendingPathComponent("second-system-file")
    let firstData = Data("first".utf8)
    let secondData = Data("second".utf8)
    try firstData.write(to: firstSourceURL)
    try secondData.write(to: secondSourceURL)

    let firstRecord = try makeRemoteAssetRecord(
      resource: resource,
      fileURL: firstSourceURL
    )
    let firstDecoded = try CloudKitRecordAdapter.decodedRecord(
      from: firstRecord,
      descriptor: AttachmentResource.cloudModelRegistration.descriptor
    )
    let firstImport = Task {
      try await store.syncDatabase.applyRemoteSave(
        recordType: firstRecord.recordType,
        snapshot: firstDecoded.snapshot,
        systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: firstRecord),
        assets: firstDecoded.assets
      )
    }
    let firstPackageURL = await gate.waitForSuspendedFile()
    #expect(FileManager.default.fileExists(atPath: firstPackageURL.path))
    let fileCountBeforeSuperseding = regularFileCount(in: rootURL)

    let secondRecord = try makeRemoteAssetRecord(
      resource: resource,
      fileURL: secondSourceURL
    )
    let secondDecoded = try CloudKitRecordAdapter.decodedRecord(
      from: secondRecord,
      descriptor: AttachmentResource.cloudModelRegistration.descriptor
    )
    let secondImport = Task {
      try await store.syncDatabase.applyRemoteSave(
        recordType: secondRecord.recordType,
        snapshot: secondDecoded.snapshot,
        systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: secondRecord),
        assets: secondDecoded.assets
      )
    }

    for _ in 0..<1_000 where regularFileCount(in: rootURL) == fileCountBeforeSuperseding {
      await Task.yield()
    }
    #expect(regularFileCount(in: rootURL) > fileCountBeforeSuperseding)
    #expect(FileManager.default.fileExists(atPath: firstPackageURL.path))

    await gate.resume()
    _ = try await firstImport.value
    _ = try await secondImport.value

    let replacements = await storage.installs().compactMap { installed -> Data? in
      guard case .replace(let data) = installed.value else { return nil }
      return data
    }
    #expect(replacements == [firstData, secondData])
    #expect(FileManager.default.fileExists(atPath: firstPackageURL.path) == false)
    #expect(try await store.syncDatabase.pendingAssetInstallCount() == 0)
    #expect(try await store.syncDatabase.stagedAssetFileCount() == 0)
  }

  @Test
  @MainActor
  func missingOutgoingSourceDoesNotCreateDurableWork() async throws {
    let rootURL = temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storage = AssetFixtureStorage()
    let stack = try makeAssetStack(
      location: .inMemory,
      rootURL: rootURL,
      assetStore: makeAssetStore(storage: storage)
    )
    let store = try #require(
      stack.store(for: .init(rawValue: "asset-primary"))
    )
    let resource = AttachmentResource(mediaType: "missing")

    do {
      _ = try await store.prepareAssetReplacement(
        for: resource,
        at: \AttachmentResource.fileAsset
      )
      Issue.record("a missing consumer source must fail preparation")
    } catch AssetFixtureError.missingSource(let identifier) {
      #expect(identifier == resource.fileAsset.localIdentifier)
    }
    #expect(try store.pendingMutationCount() == 0)
    #expect(try await store.syncDatabase.pendingAssetMutationCount() == 0)
    #expect(try await store.syncDatabase.stagedAssetFileCount() == 0)
  }

  @Test
  @MainActor
  func cloudTransportRequiresAssetHooksForAnAssetSchema() throws {
    let rootURL = temporaryDirectoryURL()
    let schema = try CloudDataSchema(models: [AttachmentResource.self])
    let configuration = CloudDataStoreConfiguration(
      id: .init(rawValue: "asset-primary"),
      location: .inMemory,
      remoteZone: .init(
        databaseScope: .private,
        zoneID: .init(zoneName: "asset-fixture-zone")
      )
    )

    #expect(throws: CloudDataStackSetupError.assetStoreRequired) {
      try CloudKitDataStack(
        schema: schema,
        stores: CloudDataStoreDirectory(
          knownStores: [configuration],
          engineStateDirectoryURL: rootURL
        ),
        transport: .cloudKit(
          containerIdentifier: "iCloud.example.AssetFixture",
          databaseScopes: [.private]
        )
      )
    }
  }

  @Test
  func recordAdapterRoundTripsEveryFieldKindAndClearsAbsentOptionals() throws {
    let card = Card(
      kind: .text,
      body: "primitive",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      score: nil,
      isPinned: true,
      revision: 9,
      byteSize: 1_024,
      payload: nil,
      location: .init(latitude: 59.3, longitude: 18.0)
    )
    let registration = Card.cloudModelRegistration
    let snapshot = try registration.makeSnapshot(from: card)
    let outgoing = CloudDataOutgoingRecord(
      recordType: "Card",
      snapshot: snapshot,
      systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(
        of: CKRecord(
          recordType: "Card",
          recordID: cloudRecordID(recordName: card.id.uuidString)
        )
      )
    )
    let record = try CloudKitRecordAdapter.makeRecord(
      from: outgoing,
      descriptor: registration.descriptor,
      recordID: cloudRecordID(recordName: card.id.uuidString)
    )

    #expect(record.changedKeys().contains("score"))
    #expect(record.changedKeys().contains("payload"))
    let recordLocation = try #require(record["location"] as? CLLocation)
    #expect(recordLocation.coordinate.latitude == 59.3)
    #expect(recordLocation.coordinate.longitude == 18.0)
    let decoded = try CloudKitRecordAdapter.snapshot(
      from: record,
      descriptor: registration.descriptor
    )
    #expect(decoded == snapshot)

    record["body"] = Int64(42)
    #expect(
      throws: CloudKitRecordAdapterError.invalidField(
        key: "body",
        expected: .string
      )
    ) {
      try CloudKitRecordAdapter.snapshot(
        from: record,
        descriptor: registration.descriptor
      )
    }

    record["body"] = card.body
    record["isPinned"] = 0.5
    #expect(
      throws: CloudKitRecordAdapterError.invalidField(
        key: "isPinned",
        expected: .bool
      )
    ) {
      try CloudKitRecordAdapter.snapshot(
        from: record,
        descriptor: registration.descriptor
      )
    }

    var unexpectedFields = snapshot.fields
    unexpectedFields["future"] = .string("not declared")
    let invalidOutgoing = CloudDataOutgoingRecord(
      recordType: "Card",
      snapshot: .init(
        recordName: snapshot.recordName,
        fields: unexpectedFields
      ),
      systemFieldsData: nil
    )
    #expect(
      throws: CloudKitRecordAdapterError.unexpectedSnapshotField("future")
    ) {
      try CloudKitRecordAdapter.makeRecord(
        from: invalidOutgoing,
        descriptor: registration.descriptor,
        recordID: cloudRecordID(recordName: snapshot.recordName)
      )
    }

    var missingRequiredFields = snapshot.fields
    missingRequiredFields.removeValue(forKey: "body")
    #expect(
      throws: CloudKitRecordAdapterError.missingRequiredSnapshotField("body")
    ) {
      try CloudKitRecordAdapter.makeRecord(
        from: .init(
          recordType: "Card",
          snapshot: .init(
            recordName: snapshot.recordName,
            fields: missingRequiredFields
          ),
          systemFieldsData: nil
        ),
        descriptor: registration.descriptor,
        recordID: cloudRecordID(recordName: snapshot.recordName)
      )
    }

    var wrongKindFields = snapshot.fields
    wrongKindFields["body"] = .int(42)
    #expect(
      throws: CloudKitRecordAdapterError.snapshotFieldKindMismatch(
        key: "body",
        expected: .string,
        actual: .int
      )
    ) {
      try CloudKitRecordAdapter.makeRecord(
        from: .init(
          recordType: "Card",
          snapshot: .init(
            recordName: snapshot.recordName,
            fields: wrongKindFields
          ),
          systemFieldsData: nil
        ),
        descriptor: registration.descriptor,
        recordID: cloudRecordID(recordName: snapshot.recordName)
      )
    }

    let edge = CardEdge(cardRecordName: card.id.uuidString)
    let edgeSnapshot = try CardEdge.cloudModelRegistration.makeSnapshot(from: edge)
    let edgeRecord = try CloudKitRecordAdapter.makeRecord(
      from: .init(
        recordType: "CardEdge",
        snapshot: edgeSnapshot,
        systemFieldsData: nil
      ),
      descriptor: CardEdge.cloudModelRegistration.descriptor,
      recordID: cloudRecordID(recordName: edge.id.uuidString)
    )
    #expect(edgeRecord["cardID"] as? String == card.id.uuidString)
    #expect(
      try CloudKitRecordAdapter.snapshot(
        from: edgeRecord,
        descriptor: CardEdge.cloudModelRegistration.descriptor
      ) == edgeSnapshot
    )
  }

  @Test
  @MainActor
  func resolvedAccountChangeRestoresTransportStatus() throws {
    let stack = try makeStack(location: .inMemory)
    let observation = stack.observation
    let change = CloudDataAccountChange.signIn(current: .init(rawValue: "account"))
    let error = CloudDataErrorSummary(
      category: .account,
      operation: "read account status",
      message: "Confirm this iCloud account.",
      databaseScope: .private
    )
    observation.record(error)
    observation.markAccountChangeRequiresResolution(change, error: error)

    // Ordinary account-status callbacks must not bypass the consumer's confirmation.
    observation.markTransportAvailable()
    #expect(observation.transportAvailability == .accountChangeRequiresResolution(change))

    observation.markAccountChangeResolved()
    #expect(observation.transportAvailability == .starting)
    #expect(observation.latestError == nil)
    #expect(observation.databaseStates[.private]?.latestError == nil)
    observation.markTransportAvailable()
    #expect(observation.transportAvailability == .available)

    let retryError = CloudDataErrorSummary(
      category: .transport,
      operation: "reseed outbox",
      message: "Retry failed."
    )
    observation.markTransportDegraded(retryError)
    observation.markTransportAvailable()
    #expect(observation.transportAvailability == .degraded(retryError))
  }

  @Test
  @MainActor
  func observationUsesCountedOverlappingActivity() throws {
    let stack = try makeStack(location: .inMemory)
    let observation = stack.observation

    observation.willFetch(.private)
    observation.willFetch(.private)
    #expect(observation.isFetchingChanges)
    observation.didFetch(.private)
    #expect(observation.isFetchingChanges)
    observation.didFetch(.private)
    #expect(observation.isFetchingChanges == false)

    observation.willSend(.private)
    observation.didSend(.private, succeeded: false)
    #expect(observation.isSendingChanges == false)
    #expect(
      observation.databaseStates[.private]?.lastSuccessfulSendAt == nil
    )

    observation.willFetch(.private)
    observation.willSend(.private)
    let accountChange = CloudDataAccountChange.signOut(
      previous: .init(rawValue: "previous")
    )
    observation.markAccountChangeRequiresResolution(
      accountChange,
      error: .init(
        category: .account,
        operation: "test",
        message: "test"
      )
    )
    #expect(observation.isSynchronizing == false)
    #expect(
      observation.transportAvailability
        == .accountChangeRequiresResolution(accountChange)
    )
  }

  @Test
  func transportConfigurationUsesExplicitStableSubscriptionIDs() {
    let explicitPrivateID = CloudDataSubscriptionID(
      rawValue: "example.sync.private.v1"
    )
    let configuration = CloudKitTransportCoordinator.Configuration(
      containerIdentifier: "iCloud.example",
      databaseScopes: [.private, .shared],
      subscriptionIDs: [.private: explicitPrivateID],
      automaticallySync: true
    )

    #expect(configuration.subscriptionID(for: .private) == explicitPrivateID.rawValue)
    #expect(configuration.subscriptionID(for: .shared) == "CloudKitDataStack.shared")
  }

  @Test
  @MainActor
  func cloudConfigurationRejectsInvalidSubscriptionIDs() throws {
    let schema = try CloudDataSchema(models: [Card.self])
    let directory = CloudDataStoreDirectory(
      knownStores: [],
      engineStateDirectoryURL: temporaryDirectoryURL()
    )

    #expect(
      throws: CloudDataStackSetupError.emptySubscriptionID(scope: .private)
    ) {
      try CloudKitDataStack(
        schema: schema,
        stores: directory,
        transport: .cloudKit(
          containerIdentifier: "iCloud.example",
          databaseScopes: [.private],
          subscriptionIDs: [.private: .init(rawValue: "")]
        )
      )
    }
    #expect(
      throws: CloudDataStackSetupError.subscriptionIDForDisabledScope(
        scope: .shared
      )
    ) {
      try CloudKitDataStack(
        schema: schema,
        stores: directory,
        transport: .cloudKit(
          containerIdentifier: "iCloud.example",
          databaseScopes: [.private],
          subscriptionIDs: [
            .shared: .init(rawValue: "example.sync.shared.v1")
          ]
        )
      )
    }
  }

  @Test
  @MainActor
  func cloudConfigurationRejectsAnUnmanagedStoreScope() throws {
    let schema = try CloudDataSchema(models: [Card.self, Attachment.self])
    let store = CloudDataStoreConfiguration(
      id: .init(rawValue: "shared"),
      location: .inMemory,
      remoteZone: .init(
        databaseScope: .shared,
        zoneID: .init(zoneName: "shared-zone", owner: .named("owner"))
      )
    )
    let directory = CloudDataStoreDirectory(
      knownStores: [store],
      engineStateDirectoryURL: temporaryDirectoryURL()
    )

    #expect(
      throws: CloudDataStackSetupError.storeScopeNotEnabled(
        storeID: store.id,
        scope: .shared
      )
    ) {
      try CloudKitDataStack(
        schema: schema,
        stores: directory,
        transport: .cloudKit(
          containerIdentifier: "iCloud.example",
          databaseScopes: [.private]
        )
      )
    }
  }

  @Test
  @MainActor
  func setupRejectsDuplicateDurableStoreFiles() throws {
    let schema = try CloudDataSchema(models: [Card.self])
    let rootURL = temporaryDirectoryURL()
    let storeURL = rootURL.appendingPathComponent("content.store")
    let stores = [
      CloudDataStoreConfiguration(
        id: .init(rawValue: "one"),
        location: .file(storeURL),
        remoteZone: .init(
          databaseScope: .private,
          zoneID: .init(zoneName: "one")
        )
      ),
      CloudDataStoreConfiguration(
        id: .init(rawValue: "two"),
        location: .file(storeURL),
        remoteZone: .init(
          databaseScope: .private,
          zoneID: .init(zoneName: "two")
        )
      ),
    ]

    #expect(
      throws: CloudDataStackSetupError.duplicateStoreFileURL(
        storeURL.standardizedFileURL.resolvingSymlinksInPath()
      )
    ) {
      try CloudKitDataStack(
        schema: schema,
        stores: .init(
          knownStores: stores,
          engineStateDirectoryURL: rootURL.appendingPathComponent("state")
        ),
        transport: .offline
      )
    }
  }

  @Test
  @MainActor
  func setupRejectsCurrentUserAsASharedZoneOwner() throws {
    let schema = try CloudDataSchema(models: [Card.self])
    let store = CloudDataStoreConfiguration(
      id: .init(rawValue: "shared"),
      location: .inMemory,
      remoteZone: .init(
        databaseScope: .shared,
        zoneID: .init(zoneName: "shared-zone")
      )
    )

    #expect(
      throws: CloudDataStackSetupError.sharedZoneRequiresNamedOwner(
        storeID: store.id
      )
    ) {
      try CloudKitDataStack(
        schema: schema,
        stores: .init(
          knownStores: [store],
          engineStateDirectoryURL: temporaryDirectoryURL()
        ),
        transport: .cloudKit(
          containerIdentifier: "iCloud.example",
          databaseScopes: [.shared]
        )
      )
    }
  }

  @Test
  @MainActor
  func cloudConfiguredStackWritesBeforeTransportStarts() throws {
    let rootURL = temporaryDirectoryURL()
    let schema = try CloudDataSchema(models: [Card.self])
    let configuration = CloudDataStoreConfiguration(
      id: .init(rawValue: "primary"),
      location: .inMemory,
      remoteZone: .init(
        databaseScope: .private,
        zoneID: .init(zoneName: "fixture-zone")
      )
    )
    let stack = try CloudKitDataStack(
      schema: schema,
      stores: .init(
        knownStores: [configuration],
        engineStateDirectoryURL: rootURL.appendingPathComponent("engine-state")
      ),
      transport: .cloudKit(
        containerIdentifier: "iCloud.example",
        databaseScopes: [.private]
      )
    )
    let store = try #require(stack.store(for: configuration.id))

    #expect(stack.observation.transportAvailability == .starting)
    try store.transaction { transaction in
      try transaction.insert(
        Card(kind: .text, body: "local first", createdAt: .now)
      )
    }
    #expect(try store.pendingMutationCount() == 1)
    #expect(stack.observation.pendingMutationCount == 1)
  }

  @Test
  func engineStateIsIndependentAndCompatibilityGatedByScope() throws {
    let directoryURL = temporaryDirectoryURL()
    let serialization = try JSONDecoder().decode(
      CKSyncEngine.State.Serialization.self,
      from: Data(#"{"data":""}"#.utf8)
    )
    let stateStore = CloudDataEngineStateStore(
      directoryURL: directoryURL,
      containerIdentifier: "iCloud.example",
      wireSchemaFingerprint: "schema-a",
      replayGeneration: 1
    )

    try stateStore.save(serialization, scope: .private)
    #expect(stateStore.load(scope: .private) != nil)
    #expect(stateStore.load(scope: .shared) == nil)

    let changedSchema = CloudDataEngineStateStore(
      directoryURL: directoryURL,
      containerIdentifier: "iCloud.example",
      wireSchemaFingerprint: "schema-b",
      replayGeneration: 1
    )
    #expect(changedSchema.load(scope: .private) == nil)

    let changedReplayGeneration = CloudDataEngineStateStore(
      directoryURL: directoryURL,
      containerIdentifier: "iCloud.example",
      wireSchemaFingerprint: "schema-a",
      replayGeneration: 2
    )
    #expect(changedReplayGeneration.load(scope: .private) == nil)

    let changedContainer = CloudDataEngineStateStore(
      directoryURL: directoryURL,
      containerIdentifier: "iCloud.other",
      wireSchemaFingerprint: "schema-a",
      replayGeneration: 1
    )
    #expect(changedContainer.load(scope: .private) == nil)

    let authorizedAccount = CloudDataAccountIdentifier(rawValue: "authorized")
    try stateStore.saveAuthorizedAccount(authorizedAccount)
    #expect(try stateStore.loadAuthorizedAccount() == authorizedAccount)
    #expect(try changedSchema.loadAuthorizedAccount() == authorizedAccount)
    #expect(try changedReplayGeneration.loadAuthorizedAccount() == authorizedAccount)
    #expect(
      throws: CloudDataEngineStateStoreError.invalidAuthorizedAccount
    ) {
      try changedContainer.loadAuthorizedAccount()
    }

    let accountChange = CloudDataAccountChange.switchAccounts(
      previous: .init(rawValue: "previous"),
      current: .init(rawValue: "current")
    )
    try stateStore.savePendingAccountChange(accountChange)
    #expect(try stateStore.loadPendingAccountChange() == accountChange)
    #expect(
      throws: CloudDataEngineStateStoreError.invalidPendingAccountChange
    ) {
      try changedContainer.loadPendingAccountChange()
    }
    try stateStore.clearPendingAccountChange()
    #expect(try stateStore.loadPendingAccountChange() == nil)
  }

  @Test
  func accountAuthorizationDistinguishesReestablishmentFromARealSwitch() {
    let accountA = CloudDataAccountIdentifier(rawValue: "account-a")
    let accountB = CloudDataAccountIdentifier(rawValue: "account-b")

    #expect(
      CloudDataAccountAuthorization.disposition(
        for: .signIn(current: accountA),
        authorizedAccount: accountA
      ) == .reestablished
    )
    #expect(
      CloudDataAccountAuthorization.disposition(
        for: .signIn(current: accountA),
        authorizedAccount: nil
      ) == .requiresResolution(.signIn(current: accountA))
    )
    #expect(
      CloudDataAccountAuthorization.disposition(
        for: .signIn(current: accountB),
        authorizedAccount: accountA
      )
        == .requiresResolution(
          .switchAccounts(previous: accountA, current: accountB)
        )
    )
    #expect(
      CloudDataAccountAuthorization.authorizedAccount(
        afterResolving: .signOut(previous: accountA),
        existingAccount: accountA
      ) == accountA
    )
    #expect(
      CloudDataAccountAuthorization.authorizedAccount(
        afterResolving: .switchAccounts(previous: accountA, current: accountB),
        existingAccount: accountA
      ) == accountB
    )
  }

  @Test
  @MainActor
  func pendingAccountChangeSurvivesRestartAndKeepsLocalWritesReady() async throws {
    let rootURL = temporaryDirectoryURL()
    let containerIdentifier = "iCloud.example"
    let schema = try CloudDataSchema(models: [Card.self])
    let stateStore = CloudDataEngineStateStore(
      directoryURL: rootURL.appendingPathComponent("engine-state"),
      containerIdentifier: containerIdentifier,
      wireSchemaFingerprint: schema.wireSchemaFingerprint,
      replayGeneration: schema.replayGeneration
    )
    let accountChange = CloudDataAccountChange.switchAccounts(
      previous: .init(rawValue: "previous"),
      current: .init(rawValue: "current")
    )
    try stateStore.savePendingAccountChange(accountChange)
    let eventRecorder = TransportEventRecorder()

    let configuration = CloudDataStoreConfiguration(
      id: .init(rawValue: "primary"),
      location: .inMemory,
      remoteZone: .init(
        databaseScope: .private,
        zoneID: .init(zoneName: "fixture-zone")
      )
    )
    let stack = try CloudKitDataStack(
      schema: schema,
      stores: .init(
        knownStores: [configuration],
        engineStateDirectoryURL: stateStore.directoryURL
      ),
      transport: .cloudKit(
        containerIdentifier: containerIdentifier,
        databaseScopes: [.private],
        automaticallySync: false
      ),
      eventHandler: CloudDataTransportEventHandler { event in
        await eventRecorder.append(event)
      }
    )

    await stack.start()
    let events = await eventRecorder.snapshot()
    #expect(
      stack.observation.transportAvailability
        == .accountChangeRequiresResolution(accountChange)
    )
    #expect(events == [.accountChangeRequiresResolution(accountChange)])

    let store = try #require(stack.store(for: configuration.id))
    try store.transaction { transaction in
      try transaction.insert(
        Card(kind: .text, body: "stays local", createdAt: .now)
      )
    }
    #expect(try store.pendingMutationCount() == 1)

    do {
      try await stack.sendChanges()
      Issue.record("transport must remain suspended until account policy resolves")
    } catch let error as CloudDataTransportOperationError {
      #expect(error == .accountChangeRequiresResolution(accountChange))
    }
  }

  @MainActor
  private func makeStack(
    location: CloudDataStoreLocation,
    rootURL: URL? = nil
  ) throws -> CloudKitDataStack {
    let rootURL = rootURL ?? temporaryDirectoryURL()
    let schema = try CloudDataSchema(
      replayGeneration: 1,
      models: [
        Card.self,
        CardEdge.self,
        Attachment.self,
        StringIdentityModel.self,
      ]
    )
    let configuration = CloudDataStoreConfiguration(
      id: .init(rawValue: "primary"),
      location: location,
      remoteZone: .init(
        databaseScope: .private,
        zoneID: .init(zoneName: "fixture-zone")
      )
    )
    return try CloudKitDataStack(
      schema: schema,
      stores: CloudDataStoreDirectory(
        knownStores: [configuration],
        engineStateDirectoryURL: rootURL.appendingPathComponent("engine-state")
      ),
      transport: .offline
    )
  }

  @MainActor
  private func makeAssetStack(
    location: CloudDataStoreLocation,
    rootURL: URL,
    assetStore: CloudDataAssetStore
  ) throws -> CloudKitDataStack {
    let schema = try CloudDataSchema(
      models: [AttachmentResource.self]
    )
    let configuration = CloudDataStoreConfiguration(
      id: .init(rawValue: "asset-primary"),
      location: location,
      remoteZone: .init(
        databaseScope: .private,
        zoneID: .init(zoneName: "asset-fixture-zone")
      )
    )
    return try CloudKitDataStack(
      schema: schema,
      stores: CloudDataStoreDirectory(
        knownStores: [configuration],
        engineStateDirectoryURL: rootURL.appendingPathComponent("engine-state")
      ),
      transport: .offline,
      assetStore: assetStore
    )
  }

  private func temporaryDirectoryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudKitDataStackTests")
      .appendingPathComponent(UUID().uuidString)
  }

  private func cloudRecordID(
    recordName: String,
    zoneName: String = "fixture-zone"
  ) -> CKRecord.ID {
    CKRecord.ID(
      recordName: recordName,
      zoneID: CKRecordZone.ID(
        zoneName: zoneName,
        ownerName: CKCurrentUserDefaultName
      )
    )
  }

  private func makeRemoteAssetRecord(
    resource: AttachmentResource,
    fileURL: URL
  ) throws -> CKRecord {
    let record = try CloudKitRecordAdapter.makeRecord(
      from: .init(
        recordType: "AttachmentResource",
        snapshot: try AttachmentResource.cloudModelRegistration.makeSnapshot(
          from: resource
        ),
        systemFieldsData: nil
      ),
      descriptor: AttachmentResource.cloudModelRegistration.descriptor,
      recordID: cloudRecordID(
        recordName: resource.id.uuidString,
        zoneName: "asset-fixture-zone"
      )
    )
    record["file"] = CKAsset(fileURL: fileURL)
    return record
  }

  private func regularFileCount(in directoryURL: URL) -> Int {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [.isRegularFileKey]
      )
    else {
      return 0
    }
    return enumerator.compactMap { $0 as? URL }.count { url in
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
  }
}
