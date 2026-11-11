import CloudKitData
import Foundation
import SwiftData

/// Synchronous coordination shared by every transaction for one local store.
///
/// The package always serializes work inside one process. A consumer that opens
/// the same SQLite file from app extensions can additionally wrap each package
/// transaction in an advisory file lock through this value. The supplied
/// closure must execute `operation` exactly once and must not let it escape.
public struct CloudDataStoreCoordination: Sendable {
  public typealias CriticalSection =
    @Sendable (_ operation: () throws -> Void) throws -> Void

  private let criticalSection: CriticalSection

  /// Uses only the package's process-local lock.
  public static let processLocal = Self { operation in
    try operation()
  }

  public init(performCriticalSection: @escaping CriticalSection) {
    self.criticalSection = performCriticalSection
  }

  func withCriticalSection<Output>(
    _ operation: () throws -> Output
  ) throws -> Output {
    let result = CriticalSectionResult<Output>()
    try criticalSection {
      result.value = Swift.Result(catching: operation)
    }
    guard let value = result.value else {
      preconditionFailure("CloudDataStoreCoordination must execute its operation exactly once.")
    }
    return try value.get()
  }
}

private final class CriticalSectionResult<Success>: @unchecked Sendable {
  var value: Result<Success, any Error>?
}

/// Decision made before generated scalar mapping mutates an incoming record.
public enum CloudDataRemoteSaveAction: Sendable, Hashable {
  /// Apply the supplied snapshot through the generated registration.
  case apply(CloudRecordSnapshot)

  /// Keep the already-materialized model unchanged while accepting new server
  /// metadata. This is intended for immutable, append-only domain records.
  case preserveExisting
}

/// Context for a consumer's narrow pre-merge policy.
///
/// `modelContext` and `existingModel` are valid only for the synchronous policy
/// invocation. They must not be retained or used from another executor.
public struct CloudDataRemoteSavePolicyContext: @unchecked Sendable {
  public let storeID: CloudDataStoreID
  public let recordType: String
  public let snapshot: CloudRecordSnapshot
  public let acceptedAt: Date
  public let modelContext: ModelContext
  public let existingModel: (any PersistentModel)?
}

/// Context delivered after generated mapping and relationship repair, before
/// the same SwiftData transaction commits.
///
/// The scoped model values must not escape this synchronous invocation.
public struct CloudDataAppliedRemoteSaveContext: @unchecked Sendable {
  public let storeID: CloudDataStoreID
  public let recordType: String
  public let recordName: String
  public let acceptedAt: Date
  public let modelContext: ModelContext
  public let model: any PersistentModel
  public let wasInserted: Bool
}

/// Consumer handling for one remote tombstone.
public enum CloudDataRemoteDeleteAction: Sendable, Hashable {
  /// Use the package default: local pending work wins, otherwise delete the
  /// generated model and enqueue removal for every declared asset slot.
  case applyDefault

  /// The consumer already applied its domain-specific deletion in the supplied
  /// context. Package metadata and unresolved relationship work are removed.
  /// When `discardPendingMutation` is true, the server tombstone also wins over
  /// locally pending save/delete work and its asset staging.
  case handled(discardPendingMutation: Bool)
}

/// Context for logical deletion and other domain-specific tombstone policy.
///
/// The context is synchronous and transaction-scoped. Consumers may mutate
/// application models through `modelContext`, but must not save or retain it.
public struct CloudDataRemoteDeletePolicyContext: @unchecked Sendable {
  public let storeID: CloudDataStoreID
  public let recordType: String
  public let recordName: String
  public let observedAt: Date
  public let hasPendingMutation: Bool
  public let modelContext: ModelContext
  public let existingModel: (any PersistentModel)?
}

/// Narrow first-party policy hooks around generated remote mapping.
///
/// Scalar decoding, materialization, relationship repair, metadata, outbox,
/// and asset retry remain package-owned. Hooks exist only for domain semantics
/// that cannot be inferred from the model declaration.
public struct CloudDataStorePolicy: Sendable {
  public typealias PrepareRemoteSave =
    @Sendable (CloudDataRemoteSavePolicyContext) throws -> CloudDataRemoteSaveAction
  public typealias DidApplyRemoteSave =
    @Sendable (CloudDataAppliedRemoteSaveContext) throws -> Void
  public typealias ApplyRemoteDelete =
    @Sendable (CloudDataRemoteDeletePolicyContext) throws -> CloudDataRemoteDeleteAction

  private let prepareRemoteSave: PrepareRemoteSave
  private let didApplyRemoteSave: DidApplyRemoteSave
  private let applyRemoteDelete: ApplyRemoteDelete

  /// Generated mapping with record-level local-pending-wins deletion policy.
  public static let generated = Self()

  public init(
    prepareRemoteSave: @escaping PrepareRemoteSave = { context in
      .apply(context.snapshot)
    },
    didApplyRemoteSave: @escaping DidApplyRemoteSave = { _ in },
    applyRemoteDelete: @escaping ApplyRemoteDelete = { _ in .applyDefault }
  ) {
    self.prepareRemoteSave = prepareRemoteSave
    self.didApplyRemoteSave = didApplyRemoteSave
    self.applyRemoteDelete = applyRemoteDelete
  }

  func prepareSave(
    _ context: CloudDataRemoteSavePolicyContext
  ) throws -> CloudDataRemoteSaveAction {
    try prepareRemoteSave(context)
  }

  func didApplySave(
    _ context: CloudDataAppliedRemoteSaveContext
  ) throws {
    try didApplyRemoteSave(context)
  }

  func applyDelete(
    _ context: CloudDataRemoteDeletePolicyContext
  ) throws -> CloudDataRemoteDeleteAction {
    try applyRemoteDelete(context)
  }
}

/// Transport lifecycle facts that require first-party follow-up policy.
public enum CloudDataTransportEvent: Sendable, Hashable {
  case importedRecord(
    storeID: CloudDataStoreID,
    remoteZone: CloudDataRemoteZone,
    recordType: String,
    recordName: String,
    creatorRecordName: String?
  )
  case importedDeletion(
    storeID: CloudDataStoreID,
    remoteZone: CloudDataRemoteZone,
    recordType: String,
    recordName: String
  )
  case acknowledgedSave(
    storeID: CloudDataStoreID,
    remoteZone: CloudDataRemoteZone,
    recordType: String,
    recordName: String,
    creatorRecordName: String?
  )
  case acknowledgedDelete(
    storeID: CloudDataStoreID,
    remoteZone: CloudDataRemoteZone,
    recordName: String
  )
  /// Transport stopped after CKSyncEngine reported an account transition.
  ///
  /// The stack retains local stores and waits for the consumer to decide
  /// whether those rows may synchronize with the new account.
  case accountChangeRequiresResolution(CloudDataAccountChange)
  case remoteShareChanged(CloudDataRemoteZone)
  case completedFetch(databaseScope: CloudDataDatabaseScope, succeeded: Bool)
}

/// Async sink for consumer-owned policy triggered by transport lifecycle facts.
///
/// Events originating from `CKSyncEngineDelegate` are delivered serially from
/// a detached task. A handler may therefore call back into its
/// `CloudKitDataStack` without inheriting CloudKit's delegate-callback context.
public struct CloudDataTransportEventHandler: Sendable {
  public typealias Handler = @Sendable (CloudDataTransportEvent) async -> Void

  private let handler: Handler

  public static let none = Self { _ in }

  public init(_ handler: @escaping Handler) {
    self.handler = handler
  }

  func send(_ event: CloudDataTransportEvent) async {
    await handler(event)
  }
}

/// FIFO delivery boundary between CKSyncEngine callbacks and consumer policy.
///
/// CloudKit forbids awaiting an engine operation that can call the delegate
/// again from inside the originating delegate callback. Enqueueing is kept
/// separate from delivery so package event processing can finish first, while
/// one detached task preserves the lifecycle-event order seen by consumers.
actor CloudDataTransportEventDispatcher {
  private let handler: CloudDataTransportEventHandler
  private var pendingEvents: [CloudDataTransportEvent] = []
  private var deliveryTask: Task<Void, Never>?

  init(handler: CloudDataTransportEventHandler) {
    self.handler = handler
  }

  /// Adds an event without awaiting consumer code in the caller's task.
  func enqueue(_ event: CloudDataTransportEvent) {
    pendingEvents.append(event)
    guard deliveryTask == nil else { return }

    deliveryTask = Task.detached { [weak self] in
      await self?.drain()
    }
  }

  private func drain() async {
    while pendingEvents.isEmpty == false {
      let event = pendingEvents.removeFirst()
      await handler.send(event)
    }
    deliveryTask = nil
  }
}
