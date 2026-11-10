import CloudKit
import CloudKitData
import Foundation

/// App-lifetime CKSyncEngine delegate and routing coordinator.
actor CloudKitTransportCoordinator: CKSyncEngineDelegate {
  struct Configuration: Sendable {
    let containerIdentifier: String
    let databaseScopes: Set<CloudDataDatabaseScope>
    let subscriptionIDs: [CloudDataDatabaseScope: CloudDataSubscriptionID]
    let automaticallySync: Bool

    func subscriptionID(for scope: CloudDataDatabaseScope) -> String {
      subscriptionIDs[scope]?.rawValue
        ?? "CloudKitDataStack.\(scope.rawValue)"
    }
  }

  typealias StoreRouter =
    @Sendable (CloudDataRemoteZone) async throws -> CloudDataStoreRoute?
  typealias RemoteZoneRemovalNotifier =
    @Sendable (CloudDataRemoteZone, CloudDataRemoteZoneRemovalReason) async -> Void

  private struct QueuedEngineEvent {
    let event: CKSyncEngine.Event
    let engine: CKSyncEngine
    let continuation: CheckedContinuation<Void, Never>
  }

  private let configuration: Configuration
  private let descriptorsByRecordType: [String: CloudModelDescriptor]
  private let stateStore: CloudDataEngineStateStore
  private let routeStore: StoreRouter
  private let notifyRemoteZoneRemoval: RemoteZoneRemovalNotifier
  private let observation: CloudDataSyncObservation
  private let eventHandler: CloudDataTransportEventHandler
  private let delegateEventDispatcher: CloudDataTransportEventDispatcher

  private var routesByRemoteZone: [CloudDataRemoteZone: CloudDataStoreRoute]
  private var container: CKContainer?
  private var removedRemoteZones: Set<CloudDataRemoteZone> = []
  private var engines: [CloudDataDatabaseScope: CKSyncEngine] = [:]
  private var fetchFailureScopes: Set<CloudDataDatabaseScope> = []
  private var sendFailureScopes: Set<CloudDataDatabaseScope> = []
  private var blockedStatePersistenceScopes: Set<CloudDataDatabaseScope> = []
  private var automaticSendScopes: Set<CloudDataDatabaseScope> = []
  private var automaticResendScopes: Set<CloudDataDatabaseScope> = []
  private var stagedRevisionsByRecordID: [CKRecord.ID: String] = [:]
  private var authorizedAccount: CloudDataAccountIdentifier?
  private var unresolvedAccountChange: CloudDataAccountChange?
  private var transportStartupFailure: CloudDataErrorSummary?
  private var eventQueue: [QueuedEngineEvent] = []
  private var isDrainingEventQueue = false
  private var hasStarted = false

  init(
    configuration: Configuration,
    descriptorsByRecordType: [String: CloudModelDescriptor],
    stateStore: CloudDataEngineStateStore,
    initialRoutes: [CloudDataStoreRoute],
    routeStore: @escaping StoreRouter,
    notifyRemoteZoneRemoval: @escaping RemoteZoneRemovalNotifier,
    observation: CloudDataSyncObservation,
    eventHandler: CloudDataTransportEventHandler
  ) {
    self.configuration = configuration
    self.descriptorsByRecordType = descriptorsByRecordType
    self.stateStore = stateStore
    self.routeStore = routeStore
    self.notifyRemoteZoneRemoval = notifyRemoteZoneRemoval
    self.observation = observation
    self.eventHandler = eventHandler
    self.delegateEventDispatcher = CloudDataTransportEventDispatcher(
      handler: eventHandler
    )
    self.routesByRemoteZone = Dictionary(
      uniqueKeysWithValues: initialRoutes.map { ($0.remoteZone, $0) }
    )
  }

  func start() async {
    guard hasStarted == false else { return }
    hasStarted = true

    do {
      try stateStore.prepareDirectory()
    } catch {
      let summary = makeErrorSummary(
        error,
        category: .localStore,
        operation: "prepare engine state directory"
      )
      transportStartupFailure = summary
      await observation.record(summary)
      await observation.markTransportDegraded(summary)
      return
    }

    do {
      authorizedAccount = try stateStore.loadAuthorizedAccount()
      if let change = try stateStore.loadPendingAccountChange() {
        unresolvedAccountChange = change
        await observation.markAccountChangeRequiresResolution(
          change,
          error: accountChangeSummary(change)
        )
        await eventHandler.send(.accountChangeRequiresResolution(change))
        return
      }
    } catch {
      let summary = makeErrorSummary(
        error,
        category: .localStore,
        operation: "load account authorization state"
      )
      transportStartupFailure = summary
      await observation.record(summary)
      await observation.markTransportDegraded(summary)
      return
    }

    initializeEngines(usePersistedState: true)
    await reseedPendingChanges(resetStaging: true)
    await observation.markTransportAvailable()

    // Account lookup is intentionally detached from stack readiness. It can
    // update diagnostics later without blocking local launch or start().
    Task { [weak self] in
      await self?.refreshAccountStatus()
    }
  }

  func localStoreDidCommit(_ route: CloudDataStoreRoute) async {
    routesByRemoteZone[route.remoteZone] = route
    guard unresolvedAccountChange == nil else { return }
    guard removedRemoteZones.contains(route.remoteZone) == false else {
      await recordFailure(
        CloudDataRoutingError.removedRemoteZone(route.remoteZone),
        category: .permission,
        operation: "route local changes",
        remoteZone: route.remoteZone
      )
      return
    }
    await seedPendingChanges(for: route, resetStaging: false)
    let scope = route.remoteZone.databaseScope
    guard
      configuration.automaticallySync,
      let engine = engines[scope]
    else {
      return
    }
    guard automaticSendScopes.insert(scope).inserted else {
      automaticResendScopes.insert(scope)
      return
    }
    defer { automaticSendScopes.remove(scope) }
    repeat {
      automaticResendScopes.remove(scope)
      do {
        try await engine.sendChanges()
      } catch {
        await recordFailure(
          error,
          category: projectedCategory(for: error, fallback: .transport),
          operation: "send local changes",
          remoteZone: route.remoteZone
        )
        return
      }
    } while automaticResendScopes.remove(scope) != nil
  }

  func reseedPendingChanges(resetStaging: Bool) async {
    guard unresolvedAccountChange == nil else { return }
    for route in Array(routesByRemoteZone.values) {
      await seedPendingChanges(for: route, resetStaging: resetStaging)
    }
  }

  func resumeAfterAccountChange() async throws {
    guard let pendingChange = unresolvedAccountChange else { return }

    let resolvedAccount = CloudDataAccountAuthorization.authorizedAccount(
      afterResolving: pendingChange,
      existingAccount: authorizedAccount
    )

    do {
      try stateStore.removeAllEngineStates()
      try stateStore.saveAuthorizedAccount(resolvedAccount)
      try stateStore.clearPendingAccountChange()
    } catch {
      let summary = makeErrorSummary(
        error,
        category: .localStore,
        operation: "clear account-scoped engine state"
      )
      await observation.record(summary)
      await observation.markTransportDegraded(summary)
      throw CloudDataTransportOperationError.failed(summary)
    }

    authorizedAccount = resolvedAccount
    unresolvedAccountChange = nil
    transportStartupFailure = nil
    blockedStatePersistenceScopes.removeAll()
    await observation.markAccountChangeResolved()
    initializeEngines(usePersistedState: false)
    await reseedPendingChanges(resetStaging: true)
    await observation.markTransportAvailable()
    Task { [weak self] in
      await self?.refreshAccountStatus()
    }
  }

  func fetchChanges() async throws {
    try validateTransportCommandReadiness()
    var firstFailure: CloudDataErrorSummary?
    for scope in configuration.databaseScopes.sorted(by: { $0.rawValue < $1.rawValue }) {
      guard let engine = engines[scope] else { continue }
      do {
        try await engine.fetchChanges()
      } catch {
        let summary = makeErrorSummary(
          error,
          category: projectedCategory(for: error, fallback: .transport),
          operation: "fetch changes",
          scope: scope
        )
        await observation.record(summary)
        if firstFailure == nil {
          firstFailure = summary
        }
      }
    }
    if let firstFailure {
      throw CloudDataTransportOperationError.failed(firstFailure)
    }
  }

  func sendChanges() async throws {
    try validateTransportCommandReadiness()
    await reseedPendingChanges(resetStaging: false)
    var firstFailure: CloudDataErrorSummary?
    for scope in configuration.databaseScopes.sorted(by: { $0.rawValue < $1.rawValue }) {
      guard let engine = engines[scope] else { continue }
      do {
        try await engine.sendChanges()
      } catch {
        let summary = makeErrorSummary(
          error,
          category: projectedCategory(for: error, fallback: .transport),
          operation: "send changes",
          scope: scope
        )
        await observation.record(summary)
        if firstFailure == nil {
          firstFailure = summary
        }
      }
    }
    if let firstFailure {
      throw CloudDataTransportOperationError.failed(firstFailure)
    }
  }

  /// Resolves the current CloudKit account without exposing CKContainer.
  func currentAccountIdentifierLookup() async -> CloudDataAccountIdentifierLookup {
    do {
      switch try await cloudContainer().accountStatus() {
      case .available:
        let recordID = try await cloudContainer().userRecordID()
        return .available(.init(rawValue: recordID.recordName))
      case .noAccount:
        return .signedOut
      case .restricted:
        return .restricted
      case .couldNotDetermine, .temporarilyUnavailable:
        return .temporarilyUnavailable
      @unknown default:
        return .temporarilyUnavailable
      }
    } catch let error as CKError where error.code == .notAuthenticated {
      return .signedOut
    } catch {
      return .temporarilyUnavailable
    }
  }

  /// Enumerates the transport's custom zones without changing engine tokens.
  func remoteZones() async throws -> [CloudDataRemoteZone] {
    try validateTransportCommandReadiness()
    var remoteZones: [CloudDataRemoteZone] = []

    for scope in configuration.databaseScopes.sorted(by: { $0.rawValue < $1.rawValue }) {
      do {
        let zones = try await cloudDatabase(for: scope).allRecordZones()
        remoteZones.append(
          contentsOf: zones.compactMap { zone in
            guard zone.zoneID.zoneName != CKRecordZone.ID.defaultZoneName else {
              return nil
            }
            return Self.remoteZone(scope: scope, zoneID: zone.zoneID)
          }
        )
      } catch {
        let summary = makeErrorSummary(
          error,
          category: projectedCategory(for: error, fallback: .transport),
          operation: "enumerate remote zones",
          scope: scope
        )
        await observation.record(summary)
        throw CloudDataTransportOperationError.failed(summary)
      }
    }

    return remoteZones.sorted(by: Self.remoteZoneSort)
  }

  /// Counts records with a disposable zone-change token.
  func remoteRecordCounts(
    in remoteZone: CloudDataRemoteZone
  ) async throws -> CloudDataRemoteRecordCounts {
    try validateTransportCommandReadiness()
    let database = cloudDatabase(for: remoteZone.databaseScope)
    let zoneID = Self.recordZoneID(from: remoteZone.zoneID)
    var changeToken: CKServerChangeToken?
    var countsByRecordType: [String: Int] = [:]

    do {
      while true {
        try Task.checkCancellation()
        let changes = try await database.recordZoneChanges(
          inZoneWith: zoneID,
          since: changeToken,
          desiredKeys: []
        )
        for result in changes.modificationResultsByID.values {
          guard let record = try? result.get().record else { continue }
          countsByRecordType[record.recordType, default: 0] += 1
        }
        guard changes.moreComing else { break }
        changeToken = changes.changeToken
      }
      return CloudDataRemoteRecordCounts(
        countsByRecordType: countsByRecordType
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let summary = makeErrorSummary(
        error,
        category: projectedCategory(for: error, fallback: .transport),
        operation: "count remote records",
        remoteZone: remoteZone
      )
      await observation.record(summary)
      throw CloudDataTransportOperationError.failed(summary)
    }
  }

  /// Deletes one exact custom zone without exposing CloudKit SDK types to the
  /// consuming application.
  func deleteRemoteZone(_ remoteZone: CloudDataRemoteZone) async throws {
    try validateTransportCommandReadiness()
    let zoneID = Self.recordZoneID(from: remoteZone.zoneID)

    do {
      _ = try await cloudDatabase(for: remoteZone.databaseScope)
        .deleteRecordZone(withID: zoneID)
    } catch let error as CKError
      where error.code == .unknownItem || error.code == .zoneNotFound
      || error.code == .userDeletedZone
    {
      // The requested end state is already true.
    } catch {
      let summary = makeErrorSummary(
        error,
        category: projectedCategory(for: error, fallback: .transport),
        operation: "delete remote zone",
        remoteZone: remoteZone
      )
      await observation.record(summary)
      throw CloudDataTransportOperationError.failed(summary)
    }

    discardRoute(remoteZone)
  }

  /// Drops in-process routing after the consumer releases a local store.
  func discardRoute(_ remoteZone: CloudDataRemoteZone) {
    if let engine = engines[remoteZone.databaseScope] {
      removeEnginePendingChanges(for: remoteZone, engine: engine)
    }
    routesByRemoteZone.removeValue(forKey: remoteZone)
    removedRemoteZones.insert(remoteZone)
  }

  // MARK: - CKSyncEngineDelegate

  func handleEvent(
    _ event: CKSyncEngine.Event,
    syncEngine: CKSyncEngine
  ) async {
    await withCheckedContinuation { continuation in
      eventQueue.append(
        QueuedEngineEvent(
          event: event,
          engine: syncEngine,
          continuation: continuation
        )
      )
      guard isDrainingEventQueue == false else { return }
      isDrainingEventQueue = true

      // CKSyncEngine tracks delegate reentrancy through task context. The
      // continuation retains serial completion while the drain runs detached.
      Task.detached {
        await self.drainEventQueue()
      }
    }
  }

  private func drainEventQueue() async {
    while eventQueue.isEmpty == false {
      let queued = eventQueue.removeFirst()
      await processEvent(queued.event, syncEngine: queued.engine)
      queued.continuation.resume()
    }
    isDrainingEventQueue = false
  }

  private func processEvent(
    _ event: CKSyncEngine.Event,
    syncEngine: CKSyncEngine
  ) async {
    guard
      let scope = Self.databaseScope(from: syncEngine.database.databaseScope),
      Self.isCurrent(syncEngine, engines[scope])
    else {
      return
    }

    switch event {
    case .stateUpdate(let update):
      guard blockedStatePersistenceScopes.contains(scope) == false else {
        return
      }
      do {
        try stateStore.save(update.stateSerialization, scope: scope)
      } catch {
        let summary = makeErrorSummary(
          error,
          category: .localStore,
          operation: "persist engine state",
          scope: scope
        )
        await observation.record(summary)
        await observation.markTransportDegraded(summary)
      }

    case .accountChange(let change):
      guard let projectedChange = Self.accountChange(from: change.changeType) else {
        await recordFailure(
          CloudDataAccountStatusError.unknown,
          category: .account,
          operation: "project account change",
          scope: scope
        )
        return
      }
      switch CloudDataAccountAuthorization.disposition(
        for: projectedChange,
        authorizedAccount: authorizedAccount
      ) {
      case .reestablished:
        await handleAuthorizedAccountReestablishment(
          scope: scope,
          engine: syncEngine
        )

      case .requiresResolution(let changeRequiringResolution):
        await suspendForAccountChange(changeRequiringResolution)
      }

    case .fetchedDatabaseChanges(let changes):
      await handleFetchedDatabaseChanges(changes, scope: scope, engine: syncEngine)

    case .fetchedRecordZoneChanges(let changes):
      for modification in changes.modifications {
        await handleFetchedRecord(modification.record, scope: scope)
      }
      for deletion in changes.deletions {
        await handleFetchedDeletion(
          recordID: deletion.recordID,
          recordType: deletion.recordType,
          scope: scope
        )
      }

    case .sentDatabaseChanges(let changes):
      for failure in changes.failedZoneSaves {
        await recordFailure(
          failure.error,
          category: category(for: failure.error),
          operation: "save zone",
          scope: scope,
          zoneName: failure.zone.zoneID.zoneName
        )
        sendFailureScopes.insert(scope)
      }
      for (zoneID, error) in changes.failedZoneDeletes {
        await recordFailure(
          error,
          category: category(for: error),
          operation: "delete zone",
          scope: scope,
          zoneName: zoneID.zoneName
        )
        sendFailureScopes.insert(scope)
      }

    case .sentRecordZoneChanges(let changes):
      await handleSentRecordZoneChanges(changes, scope: scope, engine: syncEngine)

    case .willFetchChanges:
      fetchFailureScopes.remove(scope)
      await observation.willFetch(scope)

    case .willFetchRecordZoneChanges:
      break

    case .didFetchRecordZoneChanges(let event):
      if let error = event.error {
        fetchFailureScopes.insert(scope)
        await recordFailure(
          error,
          category: category(for: error),
          operation: "fetch zone changes",
          scope: scope,
          zoneName: event.zoneID.zoneName
        )
      }

    case .didFetchChanges:
      let succeeded = fetchFailureScopes.remove(scope) == nil
      await observation.didFetch(scope, succeeded: succeeded)
      await delegateEventDispatcher.enqueue(
        .completedFetch(databaseScope: scope, succeeded: succeeded)
      )

    case .willSendChanges:
      sendFailureScopes.remove(scope)
      await observation.willSend(scope)

    case .didSendChanges:
      let succeeded = sendFailureScopes.remove(scope) == nil
      await observation.didSend(scope, succeeded: succeeded)

    @unknown default:
      break
    }
  }

  func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    guard
      let scope = Self.databaseScope(from: syncEngine.database.databaseScope),
      Self.isCurrent(syncEngine, engines[scope])
    else {
      return nil
    }

    let requested = syncEngine.state.pendingRecordZoneChanges.filter {
      context.options.scope.contains($0)
    }
    var eligible: [CKSyncEngine.PendingRecordZoneChange] = []
    eligible.reserveCapacity(min(requested.count, 250))

    for change in requested {
      guard eligible.count < 250 else { break }
      guard let recordID = Self.recordID(from: change) else { continue }
      let remoteZone = Self.remoteZone(scope: scope, zoneID: recordID.zoneID)

      do {
        guard let route = try await resolveRoute(for: remoteZone) else { continue }
        guard Self.isCurrent(syncEngine, engines[scope]) else { return nil }
        guard
          let durable = try await route.database.pendingChange(
            recordName: recordID.recordName
          )
        else {
          syncEngine.state.remove(pendingRecordZoneChanges: [change])
          continue
        }
        guard Self.isCurrent(syncEngine, engines[scope]) else { return nil }
        guard descriptorsByRecordType[durable.recordType] != nil else {
          syncEngine.state.remove(pendingRecordZoneChanges: [change])
          await recordUnknownRecordType(
            durable.recordType,
            operation: "stage outbox",
            remoteZone: remoteZone,
            recordName: durable.recordName
          )
          continue
        }

        switch (change, durable.kind) {
        case (.saveRecord, .save):
          eligible.append(change)
        case (.deleteRecord, .delete):
          if let revision = try await route.database.stageDelete(
            recordName: recordID.recordName
          ) {
            guard Self.isCurrent(syncEngine, engines[scope]) else { return nil }
            stagedRevisionsByRecordID[recordID] = revision
            eligible.append(change)
            let metrics = try await route.database.metrics()
            await observation.updateStoreMetrics(route.storeID, metrics: metrics)
          }
        case (.saveRecord, .delete), (.deleteRecord, .save):
          // Durable outbox identity wins over stale CKSyncEngine state.
          syncEngine.state.remove(pendingRecordZoneChanges: [change])
          addPendingChange(durable, route: route, engine: syncEngine)
        @unknown default:
          continue
        }
      } catch {
        await recordFailure(
          error,
          category: .localStore,
          operation: "stage outbox",
          remoteZone: remoteZone,
          recordName: recordID.recordName
        )
      }
    }

    guard eligible.isEmpty == false else { return nil }
    return await CKSyncEngine.RecordZoneChangeBatch(
      pendingChanges: eligible
    ) { recordID in
      await self.provideRecord(recordID, engine: syncEngine)
    }
  }

  // MARK: - Outbox

  private func seedPendingChanges(
    for route: CloudDataStoreRoute,
    resetStaging: Bool
  ) async {
    guard removedRemoteZones.contains(route.remoteZone) == false else { return }
    guard let engine = engines[route.remoteZone.databaseScope] else { return }
    do {
      let pending = try await route.database.pendingChanges(
        resetStaging: resetStaging
      )
      for change in pending {
        guard descriptorsByRecordType[change.recordType] != nil else {
          let recordID = Self.recordID(for: change, route: route)
          engine.state.remove(
            pendingRecordZoneChanges: [
              .saveRecord(recordID),
              .deleteRecord(recordID),
            ]
          )
          await recordUnknownRecordType(
            change.recordType,
            operation: "reseed outbox",
            remoteZone: route.remoteZone,
            recordName: change.recordName
          )
          continue
        }
        addPendingChange(change, route: route, engine: engine)
      }
      let metrics = try await route.database.metrics()
      await observation.updateStoreMetrics(route.storeID, metrics: metrics)
    } catch {
      await recordFailure(
        error,
        category: .localStore,
        operation: "reseed outbox",
        remoteZone: route.remoteZone
      )
    }
  }

  private func addPendingChange(
    _ change: CloudDataPendingChange,
    route: CloudDataStoreRoute,
    engine: CKSyncEngine
  ) {
    let recordID = Self.recordID(for: change, route: route)
    let desired: CKSyncEngine.PendingRecordZoneChange
    let stale: CKSyncEngine.PendingRecordZoneChange
    switch change.kind {
    case .save:
      desired = .saveRecord(recordID)
      stale = .deleteRecord(recordID)
    case .delete:
      desired = .deleteRecord(recordID)
      stale = .saveRecord(recordID)
    }
    engine.state.remove(pendingRecordZoneChanges: [stale])
    engine.state.add(pendingRecordZoneChanges: [desired])
  }

  private func provideRecord(
    _ recordID: CKRecord.ID,
    engine: CKSyncEngine
  ) async -> CKRecord? {
    guard
      let scope = Self.databaseScope(from: engine.database.databaseScope),
      Self.isCurrent(engine, engines[scope])
    else {
      return nil
    }
    let remoteZone = Self.remoteZone(scope: scope, zoneID: recordID.zoneID)
    do {
      guard let route = try await resolveRoute(for: remoteZone) else { return nil }
      guard Self.isCurrent(engine, engines[scope]) else { return nil }
      guard
        let outgoing = try await route.database.prepareOutgoingSave(
          recordName: recordID.recordName
        )
      else {
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
      }
      guard Self.isCurrent(engine, engines[scope]) else { return nil }
      guard let descriptor = descriptorsByRecordType[outgoing.recordType] else {
        throw CloudDataStoreRuntimeError.unknownRecordType(outgoing.recordType)
      }
      let record = try CloudKitRecordAdapter.makeRecord(
        from: outgoing,
        descriptor: descriptor,
        recordID: recordID
      )
      stagedRevisionsByRecordID[recordID] = outgoing.revision
      let metrics = try await route.database.metrics()
      await observation.updateStoreMetrics(route.storeID, metrics: metrics)
      return record
    } catch {
      await recordFailure(
        error,
        category: error is CloudKitRecordAdapterError ? .schema : .localStore,
        operation: "build outgoing record",
        remoteZone: remoteZone,
        recordName: recordID.recordName
      )
      return nil
    }
  }

  // MARK: - Incoming and acknowledgements

  private func handleFetchedDatabaseChanges(
    _ changes: CKSyncEngine.Event.FetchedDatabaseChanges,
    scope: CloudDataDatabaseScope,
    engine: CKSyncEngine
  ) async {
    for modification in changes.modifications {
      let remoteZone = Self.remoteZone(scope: scope, zoneID: modification.zoneID)
      removedRemoteZones.remove(remoteZone)
      do {
        _ = try await resolveRoute(for: remoteZone)
      } catch {
        blockedStatePersistenceScopes.insert(scope)
        await recordFailure(
          error,
          category: .importFailure,
          operation: "materialize remote zone",
          remoteZone: remoteZone
        )
      }
    }

    for deletion in changes.deletions {
      let remoteZone = Self.remoteZone(scope: scope, zoneID: deletion.zoneID)
      removeEnginePendingChanges(for: remoteZone, engine: engine)
      routesByRemoteZone.removeValue(forKey: remoteZone)
      removedRemoteZones.insert(remoteZone)
      await notifyRemoteZoneRemoval(
        remoteZone,
        Self.removalReason(from: deletion.reason)
      )
    }
  }

  private func handleFetchedRecord(
    _ record: CKRecord,
    scope: CloudDataDatabaseScope
  ) async {
    let remoteZone = Self.remoteZone(scope: scope, zoneID: record.recordID.zoneID)
    if record is CKShare || record.recordType == CKRecord.SystemType.share {
      do {
        _ = try await resolveRoute(for: remoteZone)
        await delegateEventDispatcher.enqueue(.remoteShareChanged(remoteZone))
      } catch {
        fetchFailureScopes.insert(scope)
        blockedStatePersistenceScopes.insert(scope)
        await recordFailure(
          error,
          category: .importFailure,
          operation: "route share record",
          remoteZone: remoteZone,
          recordName: record.recordID.recordName
        )
      }
      return
    }
    var resolvedRoute: CloudDataStoreRoute?
    guard let descriptor = descriptorsByRecordType[record.recordType] else {
      fetchFailureScopes.insert(scope)
      await recordUnknownRecordType(
        record.recordType,
        operation: "import record",
        remoteZone: remoteZone,
        recordName: record.recordID.recordName
      )
      return
    }

    do {
      guard let route = try await resolveRoute(for: remoteZone) else {
        throw CloudDataRoutingError.unknownRemoteZone(remoteZone)
      }
      resolvedRoute = route
      let decoded = try CloudKitRecordAdapter.decodedRecord(
        from: record,
        descriptor: descriptor
      )
      _ = try await route.database.applyRemoteSave(
        recordType: record.recordType,
        snapshot: decoded.snapshot,
        systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: record),
        assets: decoded.assets
      )
      let metrics = try await route.database.metrics()
      await observation.updateStoreMetrics(route.storeID, metrics: metrics)
      await delegateEventDispatcher.enqueue(
        .importedRecord(
          storeID: route.storeID,
          remoteZone: remoteZone,
          recordType: record.recordType,
          recordName: record.recordID.recordName,
          creatorRecordName: record.creatorUserRecordID?.recordName
        )
      )
    } catch {
      fetchFailureScopes.insert(scope)
      blockedStatePersistenceScopes.insert(scope)
      // Asset installation can fail after its replay row is committed. Refresh
      // metrics on that path so observation immediately exposes durable work.
      if let resolvedRoute,
        let metrics = try? await resolvedRoute.database.metrics()
      {
        await observation.updateStoreMetrics(resolvedRoute.storeID, metrics: metrics)
      }
      await recordFailure(
        error,
        category: error is CloudKitRecordAdapterError ? .schema : .importFailure,
        operation: "import record",
        remoteZone: remoteZone,
        recordName: record.recordID.recordName
      )
    }
  }

  private func handleFetchedDeletion(
    recordID: CKRecord.ID,
    recordType: String,
    scope: CloudDataDatabaseScope
  ) async {
    let remoteZone = Self.remoteZone(scope: scope, zoneID: recordID.zoneID)
    if recordType == CKRecord.SystemType.share {
      do {
        _ = try await resolveRoute(for: remoteZone)
        await delegateEventDispatcher.enqueue(.remoteShareChanged(remoteZone))
      } catch {
        fetchFailureScopes.insert(scope)
        blockedStatePersistenceScopes.insert(scope)
        await recordFailure(
          error,
          category: .importFailure,
          operation: "route share deletion",
          remoteZone: remoteZone,
          recordName: recordID.recordName
        )
      }
      return
    }
    var resolvedRoute: CloudDataStoreRoute?
    guard descriptorsByRecordType[recordType] != nil else {
      fetchFailureScopes.insert(scope)
      await recordUnknownRecordType(
        recordType,
        operation: "import deletion",
        remoteZone: remoteZone,
        recordName: recordID.recordName
      )
      return
    }
    do {
      guard let route = try await resolveRoute(for: remoteZone) else {
        throw CloudDataRoutingError.unknownRemoteZone(remoteZone)
      }
      resolvedRoute = route
      _ = try await route.database.applyRemoteDelete(
        recordType: recordType,
        recordName: recordID.recordName
      )
      let metrics = try await route.database.metrics()
      await observation.updateStoreMetrics(route.storeID, metrics: metrics)
      await delegateEventDispatcher.enqueue(
        .importedDeletion(
          storeID: route.storeID,
          remoteZone: remoteZone,
          recordType: recordType,
          recordName: recordID.recordName
        )
      )
    } catch {
      fetchFailureScopes.insert(scope)
      blockedStatePersistenceScopes.insert(scope)
      // A remote tombstone can leave durable consumer asset removals after an
      // installer failure. Keep that retry depth visible immediately.
      if let resolvedRoute,
        let metrics = try? await resolvedRoute.database.metrics()
      {
        await observation.updateStoreMetrics(resolvedRoute.storeID, metrics: metrics)
      }
      await recordFailure(
        error,
        category: .importFailure,
        operation: "import deletion",
        remoteZone: remoteZone,
        recordName: recordID.recordName
      )
    }
  }

  private func handleSentRecordZoneChanges(
    _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
    scope: CloudDataDatabaseScope,
    engine: CKSyncEngine
  ) async {
    for record in changes.savedRecords {
      let remoteZone = Self.remoteZone(scope: scope, zoneID: record.recordID.zoneID)
      do {
        guard let route = try await resolveRoute(for: remoteZone) else {
          throw CloudDataRoutingError.unknownRemoteZone(remoteZone)
        }
        guard
          let stagedRevision = stagedRevisionsByRecordID.removeValue(
            forKey: record.recordID
          )
        else {
          throw CloudDataStoreRuntimeError.missingMutationRevision(
            recordName: record.recordID.recordName
          )
        }
        let acknowledgement = try await route.database.acknowledgeSavedRecord(
          recordType: record.recordType,
          recordName: record.recordID.recordName,
          stagedRevision: stagedRevision,
          systemFieldsData: CloudKitRecordAdapter.encodeSystemFields(of: record)
        )
        await observation.updateStoreMetrics(
          route.storeID,
          metrics: acknowledgement.metrics
        )
        if acknowledgement.didConsumePendingMutation {
          await delegateEventDispatcher.enqueue(
            .acknowledgedSave(
              storeID: route.storeID,
              remoteZone: remoteZone,
              recordType: record.recordType,
              recordName: record.recordID.recordName,
              creatorRecordName: record.creatorUserRecordID?.recordName
            )
          )
        }
      } catch {
        sendFailureScopes.insert(scope)
        await recordFailure(
          error,
          category: .localStore,
          operation: "acknowledge saved record",
          remoteZone: remoteZone,
          recordName: record.recordID.recordName
        )
      }
    }

    for recordID in changes.deletedRecordIDs {
      await acknowledgeDelete(recordID, scope: scope)
    }

    for failure in changes.failedRecordSaves {
      let error = failure.error
      let record = failure.record
      stagedRevisionsByRecordID.removeValue(forKey: record.recordID)
      let remoteZone = Self.remoteZone(scope: scope, zoneID: record.recordID.zoneID)
      sendFailureScopes.insert(scope)
      await persistPendingFailure(
        error,
        recordID: record.recordID,
        remoteZone: remoteZone,
        operation: "save record"
      )

      switch error.code {
      case .serverRecordChanged:
        if let serverRecord = error.serverRecord {
          await handleFetchedRecord(serverRecord, scope: scope)
        }
        engine.state.add(
          pendingRecordZoneChanges: [.saveRecord(record.recordID)]
        )

      case .zoneNotFound:
        if scope == .private {
          engine.state.add(
            pendingDatabaseChanges: [
              .saveZone(CKRecordZone(zoneID: record.recordID.zoneID))
            ]
          )
          engine.state.add(
            pendingRecordZoneChanges: [.saveRecord(record.recordID)]
          )
        }

      case .unknownItem:
        do {
          if let route = try await resolveRoute(for: remoteZone) {
            try await route.database.forgetMetadata(
              recordName: record.recordID.recordName
            )
          }
        } catch {
          await recordFailure(
            error,
            category: .localStore,
            operation: "forget obsolete server metadata",
            remoteZone: remoteZone,
            recordName: record.recordID.recordName
          )
        }
        engine.state.add(
          pendingRecordZoneChanges: [.saveRecord(record.recordID)]
        )

      default:
        break
      }
    }

    for (recordID, error) in changes.failedRecordDeletes {
      let remoteZone = Self.remoteZone(scope: scope, zoneID: recordID.zoneID)
      if error.code == .unknownItem || error.code == .zoneNotFound {
        await acknowledgeDelete(recordID, scope: scope)
      } else {
        stagedRevisionsByRecordID.removeValue(forKey: recordID)
        sendFailureScopes.insert(scope)
        await persistPendingFailure(
          error,
          recordID: recordID,
          remoteZone: remoteZone,
          operation: "delete record"
        )
      }
    }
  }

  private func acknowledgeDelete(
    _ recordID: CKRecord.ID,
    scope: CloudDataDatabaseScope
  ) async {
    let remoteZone = Self.remoteZone(scope: scope, zoneID: recordID.zoneID)
    do {
      guard let route = try await resolveRoute(for: remoteZone) else {
        throw CloudDataRoutingError.unknownRemoteZone(remoteZone)
      }
      guard
        let stagedRevision = stagedRevisionsByRecordID.removeValue(
          forKey: recordID
        )
      else {
        throw CloudDataStoreRuntimeError.missingMutationRevision(
          recordName: recordID.recordName
        )
      }
      let acknowledgement = try await route.database.acknowledgeDeletedRecord(
        recordName: recordID.recordName,
        stagedRevision: stagedRevision
      )
      await observation.updateStoreMetrics(
        route.storeID,
        metrics: acknowledgement.metrics
      )
      if acknowledgement.didConsumePendingMutation {
        await delegateEventDispatcher.enqueue(
          .acknowledgedDelete(
            storeID: route.storeID,
            remoteZone: remoteZone,
            recordName: recordID.recordName
          )
        )
      }
    } catch {
      sendFailureScopes.insert(scope)
      await recordFailure(
        error,
        category: .localStore,
        operation: "acknowledge deleted record",
        remoteZone: remoteZone,
        recordName: recordID.recordName
      )
    }
  }

  private func persistPendingFailure(
    _ error: CKError,
    recordID: CKRecord.ID,
    remoteZone: CloudDataRemoteZone,
    operation: String
  ) async {
    let summary = makeErrorSummary(
      error,
      category: category(for: error),
      operation: operation,
      remoteZone: remoteZone,
      recordName: recordID.recordName
    )
    await observation.record(summary)
    do {
      if let route = try await resolveRoute(for: remoteZone) {
        try await route.database.recordPendingFailure(
          recordName: recordID.recordName,
          error: summary
        )
      }
    } catch {
      await recordFailure(
        error,
        category: .localStore,
        operation: "persist pending failure",
        remoteZone: remoteZone,
        recordName: recordID.recordName
      )
    }
  }

  // MARK: - Routing and state

  private func initializeEngines(usePersistedState: Bool) {
    engines.removeAll()
    stagedRevisionsByRecordID.removeAll()
    for scope in configuration.databaseScopes.sorted(by: { $0.rawValue < $1.rawValue }) {
      let database = cloudDatabase(for: scope)
      var engineConfiguration = CKSyncEngine.Configuration(
        database: database,
        stateSerialization: usePersistedState ? stateStore.load(scope: scope) : nil,
        delegate: self
      )
      engineConfiguration.automaticallySync = configuration.automaticallySync
      engineConfiguration.subscriptionID = configuration.subscriptionID(
        for: scope
      )
      let engine = CKSyncEngine(engineConfiguration)
      engines[scope] = engine
      addPrivateZoneChanges(to: engine, scope: scope)
    }
  }

  private func addPrivateZoneChanges(
    to engine: CKSyncEngine,
    scope: CloudDataDatabaseScope
  ) {
    guard scope == .private else { return }
    let zones = routesByRemoteZone.values
      .filter {
        $0.remoteZone.databaseScope == .private
          && removedRemoteZones.contains($0.remoteZone) == false
      }
      .map { CKRecordZone(zoneID: Self.recordZoneID(from: $0.remoteZone.zoneID)) }
    engine.state.add(pendingDatabaseChanges: zones.map { .saveZone($0) })
  }

  /// Restores package-owned pending work after CKSyncEngine confirms the same
  /// account for which the local stores were already authorized.
  private func handleAuthorizedAccountReestablishment(
    scope: CloudDataDatabaseScope,
    engine: CKSyncEngine
  ) async {
    guard Self.isCurrent(engine, engines[scope]) else { return }

    automaticSendScopes.remove(scope)
    automaticResendScopes.remove(scope)
    fetchFailureScopes.remove(scope)
    sendFailureScopes.remove(scope)
    blockedStatePersistenceScopes.remove(scope)
    stagedRevisionsByRecordID.removeAll()

    addPrivateZoneChanges(to: engine, scope: scope)
    for route in Array(routesByRemoteZone.values)
    where route.remoteZone.databaseScope == scope {
      await seedPendingChanges(for: route, resetStaging: true)
    }
    await observation.markTransportAvailable()
  }

  private func suspendForAccountChange(
    _ change: CloudDataAccountChange
  ) async {
    unresolvedAccountChange = change
    automaticSendScopes.removeAll()
    automaticResendScopes.removeAll()
    stagedRevisionsByRecordID.removeAll()

    do {
      try stateStore.savePendingAccountChange(change)
      try stateStore.removeAllEngineStates()
    } catch {
      let summary = makeErrorSummary(
        error,
        category: .localStore,
        operation: "persist account-change gate"
      )
      await observation.record(summary)
    }

    // Removing every current engine makes any later callback from pre-change
    // transport fail the identity guard in event/batch processing.
    engines.removeAll()
    for route in Array(routesByRemoteZone.values) {
      do {
        _ = try await route.database.pendingChanges(resetStaging: true)
        let metrics = try await route.database.metrics()
        await observation.updateStoreMetrics(route.storeID, metrics: metrics)
      } catch {
        await recordFailure(
          error,
          category: .localStore,
          operation: "reset staged work after account change",
          remoteZone: route.remoteZone
        )
      }
    }
    let summary = accountChangeSummary(change)
    await observation.markAccountChangeRequiresResolution(
      change,
      error: summary
    )
    await delegateEventDispatcher.enqueue(
      .accountChangeRequiresResolution(change)
    )
  }

  private func validateTransportCommandReadiness() throws {
    if let unresolvedAccountChange {
      throw CloudDataTransportOperationError.accountChangeRequiresResolution(
        unresolvedAccountChange
      )
    }
    if let transportStartupFailure {
      throw CloudDataTransportOperationError.failed(transportStartupFailure)
    }
  }

  private func resolveRoute(
    for remoteZone: CloudDataRemoteZone
  ) async throws -> CloudDataStoreRoute? {
    guard removedRemoteZones.contains(remoteZone) == false else {
      throw CloudDataRoutingError.removedRemoteZone(remoteZone)
    }
    if let route = routesByRemoteZone[remoteZone] { return route }
    guard let route = try await routeStore(remoteZone) else { return nil }
    guard route.remoteZone == remoteZone else {
      throw CloudDataStackSetupError.remoteMaterializerReturnedMismatchedZone(
        expected: remoteZone,
        actual: route.remoteZone
      )
    }
    routesByRemoteZone[remoteZone] = route
    return route
  }

  private func removeEnginePendingChanges(
    for remoteZone: CloudDataRemoteZone,
    engine: CKSyncEngine
  ) {
    let zoneID = Self.recordZoneID(from: remoteZone.zoneID)
    let recordChanges = engine.state.pendingRecordZoneChanges.filter { change in
      Self.recordID(from: change)?.zoneID == zoneID
    }
    engine.state.remove(pendingRecordZoneChanges: recordChanges)

    let databaseChanges = engine.state.pendingDatabaseChanges.filter { change in
      switch change {
      case .saveZone(let zone):
        zone.zoneID == zoneID
      case .deleteZone(let deletedZoneID):
        deletedZoneID == zoneID
      @unknown default:
        false
      }
    }
    engine.state.remove(pendingDatabaseChanges: databaseChanges)
  }

  private func refreshAccountStatus() async {
    do {
      switch try await cloudContainer().accountStatus() {
      case .available:
        await observation.markTransportAvailable()
      case .noAccount:
        await markAccountUnavailable("No iCloud account is signed in.")
      case .restricted:
        await markAccountUnavailable("iCloud access is restricted.")
      case .couldNotDetermine:
        await recordFailure(
          CloudDataAccountStatusError.couldNotDetermine,
          category: .account,
          operation: "read account status"
        )
      case .temporarilyUnavailable:
        await recordFailure(
          CloudDataAccountStatusError.temporarilyUnavailable,
          category: .account,
          operation: "read account status"
        )
      @unknown default:
        await recordFailure(
          CloudDataAccountStatusError.unknown,
          category: .account,
          operation: "read account status"
        )
      }
    } catch {
      await recordFailure(
        error,
        category: .account,
        operation: "read account status"
      )
    }
  }

  private func markAccountUnavailable(_ message: String) async {
    let summary = CloudDataErrorSummary(
      category: .account,
      operation: "read account status",
      message: message
    )
    await observation.markAccountUnavailable(summary)
  }

  private func accountChangeSummary(
    _ change: CloudDataAccountChange
  ) -> CloudDataErrorSummary {
    let transition: String
    switch change {
    case .signIn:
      transition = "sign-in"
    case .signOut:
      transition = "sign-out"
    case .switchAccounts:
      transition = "account switch"
    }
    return CloudDataErrorSummary(
      category: .account,
      operation: "resolve account change",
      message:
        "CloudKit reported \(transition) and reset account-scoped engine state. Resolve retained local data before resuming transport."
    )
  }

  private func cloudDatabase(for scope: CloudDataDatabaseScope) -> CKDatabase {
    let container = cloudContainer()
    switch scope {
    case .private:
      return container.privateCloudDatabase
    case .shared:
      return container.sharedCloudDatabase
    }
  }

  private func cloudContainer() -> CKContainer {
    if let container { return container }
    let container = CKContainer(identifier: configuration.containerIdentifier)
    self.container = container
    return container
  }

  // MARK: - Error projection

  private func recordUnknownRecordType(
    _ recordType: String,
    operation: String,
    remoteZone: CloudDataRemoteZone,
    recordName: String
  ) async {
    let summary = CloudDataErrorSummary(
      category: .schema,
      operation: operation,
      message: "Unknown record type '\(recordType)'; durable work was retained.",
      databaseScope: remoteZone.databaseScope,
      zoneName: remoteZone.zoneID.zoneName,
      recordName: recordName
    )
    await observation.record(summary)
  }

  private func recordFailure(
    _ error: any Error,
    category: CloudDataErrorCategory,
    operation: String,
    scope: CloudDataDatabaseScope? = nil,
    zoneName: String? = nil,
    remoteZone: CloudDataRemoteZone? = nil,
    recordName: String? = nil
  ) async {
    let summary = makeErrorSummary(
      error,
      category: category,
      operation: operation,
      scope: scope,
      remoteZone: remoteZone,
      zoneName: zoneName,
      recordName: recordName
    )
    await observation.record(summary)
  }

  private func makeErrorSummary(
    _ error: any Error,
    category: CloudDataErrorCategory,
    operation: String,
    scope: CloudDataDatabaseScope? = nil,
    remoteZone: CloudDataRemoteZone? = nil,
    zoneName: String? = nil,
    recordName: String? = nil
  ) -> CloudDataErrorSummary {
    let rawMessage: String
    if let cloudKitError = error as? CKError {
      rawMessage = cloudKitError.localizedDescription
    } else if let localizedError = error as? any LocalizedError,
      let description = localizedError.errorDescription
    {
      rawMessage = description
    } else {
      rawMessage = String(describing: error)
    }
    let message = String(rawMessage.prefix(500))
    return CloudDataErrorSummary(
      category: category,
      operation: operation,
      message: message,
      databaseScope: remoteZone?.databaseScope ?? scope,
      zoneName: remoteZone?.zoneID.zoneName ?? zoneName,
      recordName: recordName
    )
  }

  private func category(for error: CKError) -> CloudDataErrorCategory {
    switch error.code {
    case .notAuthenticated, .accountTemporarilyUnavailable:
      .account
    case .permissionFailure:
      .permission
    case .serverRejectedRequest, .invalidArguments, .constraintViolation:
      .schema
    case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
      .zoneBusy:
      .transport
    default:
      .unknown
    }
  }

  private func projectedCategory(
    for error: any Error,
    fallback: CloudDataErrorCategory
  ) -> CloudDataErrorCategory {
    guard let cloudKitError = error as? CKError else { return fallback }
    return category(for: cloudKitError)
  }

  // MARK: - CloudKit value conversion

  private static func isCurrent(
    _ engine: CKSyncEngine,
    _ current: CKSyncEngine?
  ) -> Bool {
    guard let current else { return false }
    return engine === current
  }

  private static func recordID(
    for change: CloudDataPendingChange,
    route: CloudDataStoreRoute
  ) -> CKRecord.ID {
    CKRecord.ID(
      recordName: change.recordName,
      zoneID: recordZoneID(from: route.remoteZone.zoneID)
    )
  }

  private static func recordID(
    from change: CKSyncEngine.PendingRecordZoneChange
  ) -> CKRecord.ID? {
    switch change {
    case .saveRecord(let recordID), .deleteRecord(let recordID):
      recordID
    @unknown default:
      nil
    }
  }

  private static func recordZoneID(
    from zoneID: CloudDataZoneID
  ) -> CKRecordZone.ID {
    let ownerName: String
    switch zoneID.owner {
    case .currentUser:
      ownerName = CKCurrentUserDefaultName
    case .named(let name):
      ownerName = name
    }
    return CKRecordZone.ID(zoneName: zoneID.zoneName, ownerName: ownerName)
  }

  private static func remoteZone(
    scope: CloudDataDatabaseScope,
    zoneID: CKRecordZone.ID
  ) -> CloudDataRemoteZone {
    let owner: CloudDataZoneOwner =
      zoneID.ownerName == CKCurrentUserDefaultName
      ? .currentUser
      : .named(zoneID.ownerName)
    return CloudDataRemoteZone(
      databaseScope: scope,
      zoneID: CloudDataZoneID(zoneName: zoneID.zoneName, owner: owner)
    )
  }

  private static func remoteZoneSort(
    _ lhs: CloudDataRemoteZone,
    _ rhs: CloudDataRemoteZone
  ) -> Bool {
    if lhs.databaseScope != rhs.databaseScope {
      return lhs.databaseScope.rawValue < rhs.databaseScope.rawValue
    }
    if lhs.zoneID.zoneName != rhs.zoneID.zoneName {
      return lhs.zoneID.zoneName < rhs.zoneID.zoneName
    }
    return ownerSortKey(lhs.zoneID.owner) < ownerSortKey(rhs.zoneID.owner)
  }

  private static func ownerSortKey(_ owner: CloudDataZoneOwner) -> String {
    switch owner {
    case .currentUser:
      ""
    case .named(let name):
      name
    }
  }

  private static func databaseScope(
    from scope: CKDatabase.Scope
  ) -> CloudDataDatabaseScope? {
    switch scope {
    case .private:
      .private
    case .shared:
      .shared
    case .public:
      nil
    @unknown default:
      nil
    }
  }

  private static func accountChange(
    from changeType: CKSyncEngine.Event.AccountChange.ChangeType
  ) -> CloudDataAccountChange? {
    switch changeType {
    case .signIn(let currentUser):
      .signIn(
        current: .init(rawValue: currentUser.recordName)
      )
    case .signOut(let previousUser):
      .signOut(
        previous: .init(rawValue: previousUser.recordName)
      )
    case .switchAccounts(let previousUser, let currentUser):
      .switchAccounts(
        previous: .init(rawValue: previousUser.recordName),
        current: .init(rawValue: currentUser.recordName)
      )
    @unknown default:
      nil
    }
  }

  private static func removalReason(
    from reason: CKDatabase.DatabaseChange.Deletion.Reason
  ) -> CloudDataRemoteZoneRemovalReason {
    switch reason {
    case .deleted:
      .deleted
    case .purged:
      .purged
    case .encryptedDataReset:
      .encryptedDataReset
    @unknown default:
      .unknown
    }
  }
}

private enum CloudDataRoutingError: Error, Sendable {
  case unknownRemoteZone(CloudDataRemoteZone)
  case removedRemoteZone(CloudDataRemoteZone)
}

private enum CloudDataAccountStatusError: Error, Sendable {
  case couldNotDetermine
  case temporarilyUnavailable
  case unknown
}
