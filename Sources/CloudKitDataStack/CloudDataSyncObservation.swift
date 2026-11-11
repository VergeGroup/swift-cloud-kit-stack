import Foundation
import Observation

/// A stable error category suitable for UI and diagnostics without CKError.
public enum CloudDataErrorCategory: String, Sendable, Hashable, Codable {
  /// Opening, reading, or saving a local SwiftData/engine-state store failed.
  case localStore

  /// The iCloud account is absent, restricted, or indeterminate.
  case account

  /// Network, service, throttling, or other retryable transport work failed.
  case transport

  /// A record type, field, or deployed CloudKit schema is incompatible.
  case schema

  /// A valid transport payload could not be applied to the local domain store.
  case importFailure

  /// The account lacks permission for the requested zone or record.
  case permission

  /// A future or unclassified failure was preserved for diagnostics.
  case unknown
}

/// A bounded, transport-neutral diagnostic summary.
public struct CloudDataErrorSummary: Sendable, Hashable, Codable {
  public let category: CloudDataErrorCategory
  public let operation: String
  public let message: String
  public let occurredAt: Date
  public let databaseScope: CloudDataDatabaseScope?
  public let zoneName: String?
  public let recordName: String?

  public init(
    category: CloudDataErrorCategory,
    operation: String,
    message: String,
    occurredAt: Date = .now,
    databaseScope: CloudDataDatabaseScope? = nil,
    zoneName: String? = nil,
    recordName: String? = nil
  ) {
    self.category = category
    self.operation = operation
    self.message = String(message.prefix(500))
    self.occurredAt = occurredAt
    self.databaseScope = databaseScope
    self.zoneName = zoneName
    self.recordName = recordName
  }
}

/// Read-only diagnostic projection of one durable outbox entry.
///
/// The package's SwiftData system models remain private implementation detail;
/// consumers can inspect this value for debug UI, tests, and support tooling
/// without coupling to the outbox schema.
public struct CloudDataPendingMutationSnapshot: Sendable, Hashable {
  public let recordName: String
  public let recordType: String
  public let kind: CloudDataMutationKind
  public let enqueuedAt: Date
  public let stagedAt: Date?
  public let latestErrorCategory: CloudDataErrorCategory?
  public let latestErrorMessage: String?
  public let latestErrorAt: Date?

  public init(
    recordName: String,
    recordType: String,
    kind: CloudDataMutationKind,
    enqueuedAt: Date,
    stagedAt: Date?,
    latestErrorCategory: CloudDataErrorCategory?,
    latestErrorMessage: String?,
    latestErrorAt: Date?
  ) {
    self.recordName = recordName
    self.recordType = recordType
    self.kind = kind
    self.enqueuedAt = enqueuedAt
    self.stagedAt = stagedAt
    self.latestErrorCategory = latestErrorCategory
    self.latestErrorMessage = latestErrorMessage
    self.latestErrorAt = latestErrorAt
  }
}

/// Whether one known local store opened successfully.
public enum CloudDataLocalStoreState: Sendable, Hashable {
  /// The stable local ModelContainer is open for reads and authored writes.
  case ready

  /// The store could not be opened or materialized.
  case failed(CloudDataErrorSummary)
}

/// Cloud transport availability, intentionally independent of local stores.
public enum CloudDataTransportAvailability: Sendable, Hashable {
  /// Remote transport is deliberately disabled.
  case offline

  /// Engines are being constructed from their persisted state.
  case starting

  /// Engines are available; this does not claim all devices have converged.
  case available

  /// The current iCloud account cannot presently transport records.
  case accountUnavailable(CloudDataErrorSummary)

  /// Account-scoped local data must be resolved before transport can restart.
  case accountChangeRequiresResolution(CloudDataAccountChange)

  /// Local stores remain available while a transport/import problem persists.
  case degraded(CloudDataErrorSummary)
}

/// Observable state for one CloudKit database scope.
public struct CloudDataDatabaseSyncState: Sendable, Hashable {
  /// Number of overlapping fetch operations reported by the engine.
  public internal(set) var activeFetchCount = 0

  /// Number of overlapping send operations reported by the engine.
  public internal(set) var activeSendCount = 0

  /// Durable mutations known across stores in this database scope.
  public internal(set) var pendingMutationCount = 0

  /// Pending mutations currently handed to an outgoing batch.
  public internal(set) var stagedMutationCount = 0

  /// Explicit outgoing asset intents and incoming installs awaiting completion.
  public internal(set) var pendingAssetTransferCount = 0

  /// Most recent explicit or automatically-scheduled operation attempt.
  public internal(set) var lastAttemptAt: Date?

  /// Most recent fetch lifecycle that completed without a recorded failure.
  public internal(set) var lastSuccessfulFetchAt: Date?

  /// Most recent send lifecycle that completed without a recorded failure.
  public internal(set) var lastSuccessfulSendAt: Date?

  /// Latest bounded failure associated with this database scope.
  public internal(set) var latestError: CloudDataErrorSummary?

  /// Whether one or more fetch operations are active.
  public var isFetchingChanges: Bool { activeFetchCount > 0 }

  /// Whether one or more send operations are active.
  public var isSendingChanges: Bool { activeSendCount > 0 }

  /// Whether fetch or send work is active for this scope.
  public var isSynchronizing: Bool { isFetchingChanges || isSendingChanges }

  public init() {}
}

/// The stack-owned read model for local readiness and transport activity.
///
/// Fetch/send booleans are projections of counted CKSyncEngine lifecycle
/// events. They describe current activity only; pending depth and successful
/// timestamps remain separate and no value claims global device convergence.
@MainActor
@Observable
public final class CloudDataSyncObservation {
  /// Independent readiness for each currently-known local store.
  public private(set) var localStores: [CloudDataStoreID: CloudDataLocalStoreState] = [:]

  /// Account/transport availability, independent of local readiness.
  public private(set) var transportAvailability: CloudDataTransportAvailability

  /// Fetch/send/pending diagnostics grouped by private/shared database.
  public private(set) var databaseStates: [CloudDataDatabaseScope: CloudDataDatabaseSyncState]

  /// The latest bounded error across local and transport work.
  public private(set) var latestError: CloudDataErrorSummary?

  private var storeMetrics: [CloudDataStoreID: CloudDataStoreMetrics] = [:]
  private var storeScopes: [CloudDataStoreID: CloudDataDatabaseScope]

  init(
    stores: [CloudDataStoreConfiguration],
    transportIsOffline: Bool,
    databaseScopes: Set<CloudDataDatabaseScope>
  ) {
    self.transportAvailability = transportIsOffline ? .offline : .starting
    self.databaseStates = Dictionary(
      uniqueKeysWithValues: databaseScopes.map { ($0, CloudDataDatabaseSyncState()) }
    )
    self.storeScopes = Dictionary(
      uniqueKeysWithValues: stores.map { ($0.id, $0.remoteZone.databaseScope) }
    )
  }

  /// Whether any configured database is currently fetching changes.
  public var isFetchingChanges: Bool {
    databaseStates.values.contains(where: \.isFetchingChanges)
  }

  /// Whether any configured database is currently sending changes.
  public var isSendingChanges: Bool {
    databaseStates.values.contains(where: \.isSendingChanges)
  }

  /// Whether any configured database is currently fetching or sending.
  public var isSynchronizing: Bool {
    isFetchingChanges || isSendingChanges
  }

  /// Durable pending mutations across all open stores.
  public var pendingMutationCount: Int {
    databaseStates.values.reduce(0) { $0 + $1.pendingMutationCount }
  }

  /// Pending mutations currently staged into outgoing engine batches.
  public var stagedMutationCount: Int {
    databaseStates.values.reduce(0) { $0 + $1.stagedMutationCount }
  }

  /// Pending asset field operations across all open stores.
  public var pendingAssetTransferCount: Int {
    databaseStates.values.reduce(0) { $0 + $1.pendingAssetTransferCount }
  }

  func markLocalStoreReady(
    _ storeID: CloudDataStoreID,
    scope: CloudDataDatabaseScope,
    metrics: CloudDataStoreMetrics
  ) {
    storeScopes[storeID] = scope
    localStores[storeID] = .ready
    updateStoreMetrics(storeID, metrics: metrics)
  }

  func markLocalStoreFailed(
    _ storeID: CloudDataStoreID,
    scope: CloudDataDatabaseScope,
    error: CloudDataErrorSummary
  ) {
    storeScopes[storeID] = scope
    localStores[storeID] = .failed(error)
    latestError = error
  }

  func markTransportStarting() {
    transportAvailability = .starting
  }

  /// Starts a new transport attempt after the consumer durably authorizes the account.
  func markAccountChangeResolved() {
    transportAvailability = .starting
    if case .account? = latestError?.category {
      latestError = nil
    }
    for scope in Array(databaseStates.keys) {
      if case .account? = databaseStates[scope]?.latestError?.category {
        databaseStates[scope]?.latestError = nil
      }
    }
  }

  func markTransportAvailable() {
    switch transportAvailability {
    case .starting, .accountUnavailable:
      transportAvailability = .available
    case .offline, .available, .degraded, .accountChangeRequiresResolution:
      break
    }
  }

  func markTransportDegraded(_ error: CloudDataErrorSummary) {
    latestError = error
    switch transportAvailability {
    case .offline, .accountUnavailable, .accountChangeRequiresResolution:
      break
    case .starting, .available, .degraded:
      transportAvailability = .degraded(error)
    }
  }

  func markTransportOffline() {
    transportAvailability = .offline
  }

  func markAccountUnavailable(_ error: CloudDataErrorSummary) {
    latestError = error
    if case .accountChangeRequiresResolution = transportAvailability {
      return
    }
    transportAvailability = .accountUnavailable(error)
  }

  func markAccountChangeRequiresResolution(
    _ change: CloudDataAccountChange,
    error: CloudDataErrorSummary
  ) {
    latestError = error
    for scope in Array(databaseStates.keys) {
      var state = databaseStates[scope, default: .init()]
      state.activeFetchCount = 0
      state.activeSendCount = 0
      databaseStates[scope] = state
    }
    transportAvailability = .accountChangeRequiresResolution(change)
  }

  func record(_ error: CloudDataErrorSummary) {
    latestError = error
    if let scope = error.databaseScope {
      var state = databaseStates[scope, default: .init()]
      state.latestError = error
      databaseStates[scope] = state
    }
    switch transportAvailability {
    case .offline:
      return
    case .accountUnavailable, .accountChangeRequiresResolution:
      // Offline is intentional, and account state has higher diagnostic
      // priority than an operation-level transport or import failure.
      return
    case .starting, .available, .degraded:
      switch error.category {
      case .transport, .schema, .importFailure, .permission, .unknown:
        transportAvailability = .degraded(error)
      case .account:
        transportAvailability = .accountUnavailable(error)
      case .localStore:
        break
      }
    }
  }

  func updateStoreMetrics(
    _ storeID: CloudDataStoreID,
    metrics: CloudDataStoreMetrics
  ) {
    storeMetrics[storeID] = metrics
    guard let scope = storeScopes[storeID] else { return }

    var state = databaseStates[scope, default: .init()]
    let scopedMetrics = storeMetrics.compactMap { id, metrics -> CloudDataStoreMetrics? in
      storeScopes[id] == scope ? metrics : nil
    }
    state.pendingMutationCount = scopedMetrics.reduce(0) { $0 + $1.pendingCount }
    state.stagedMutationCount = scopedMetrics.reduce(0) { $0 + $1.stagedCount }
    state.pendingAssetTransferCount = scopedMetrics.reduce(0) {
      $0 + $1.pendingAssetTransferCount
    }
    databaseStates[scope] = state
  }

  func removeLocalStore(_ storeID: CloudDataStoreID) {
    guard let scope = storeScopes.removeValue(forKey: storeID) else { return }
    localStores.removeValue(forKey: storeID)
    storeMetrics.removeValue(forKey: storeID)

    var state = databaseStates[scope, default: .init()]
    let scopedMetrics = storeMetrics.compactMap { id, metrics -> CloudDataStoreMetrics? in
      storeScopes[id] == scope ? metrics : nil
    }
    state.pendingMutationCount = scopedMetrics.reduce(0) { $0 + $1.pendingCount }
    state.stagedMutationCount = scopedMetrics.reduce(0) { $0 + $1.stagedCount }
    state.pendingAssetTransferCount = scopedMetrics.reduce(0) {
      $0 + $1.pendingAssetTransferCount
    }
    databaseStates[scope] = state
  }

  func willFetch(_ scope: CloudDataDatabaseScope, at date: Date = .now) {
    var state = databaseStates[scope, default: .init()]
    state.activeFetchCount += 1
    state.lastAttemptAt = date
    databaseStates[scope] = state
  }

  func didFetch(
    _ scope: CloudDataDatabaseScope,
    succeeded: Bool = true,
    at date: Date = .now
  ) {
    var state = databaseStates[scope, default: .init()]
    state.activeFetchCount = max(0, state.activeFetchCount - 1)
    if succeeded {
      state.lastSuccessfulFetchAt = date
    }
    databaseStates[scope] = state
  }

  func willSend(_ scope: CloudDataDatabaseScope, at date: Date = .now) {
    var state = databaseStates[scope, default: .init()]
    state.activeSendCount += 1
    state.lastAttemptAt = date
    databaseStates[scope] = state
  }

  func didSend(
    _ scope: CloudDataDatabaseScope,
    succeeded: Bool = true,
    at date: Date = .now
  ) {
    var state = databaseStates[scope, default: .init()]
    state.activeSendCount = max(0, state.activeSendCount - 1)
    if succeeded {
      state.lastSuccessfulSendAt = date
    }
    databaseStates[scope] = state
  }
}
