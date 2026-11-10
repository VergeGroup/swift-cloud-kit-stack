import Foundation

/// A stable consumer-defined identity for one local SwiftData store.
public struct CloudDataStoreID: RawRepresentable, Sendable, Hashable, Codable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

/// A CloudKit database category supported by the stack.
///
/// The public API deliberately owns this value instead of exposing
/// `CKDatabase.Scope` to application model and feature modules.
public enum CloudDataDatabaseScope: String, CaseIterable, Sendable, Hashable, Codable {
  /// Records owned by the current iCloud account.
  case `private`

  /// Records in zones another iCloud account shared with the current user.
  case shared
}

/// A stable consumer-selected identifier for one silent database subscription.
///
/// Supplying the same value used by an earlier sync implementation lets
/// CKSyncEngine adopt that subscription without exposing CloudKit SDK types to
/// the application composition root.
public struct CloudDataSubscriptionID: RawRepresentable, Sendable, Hashable,
  Codable, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

/// An opaque CloudKit account identity projected out of `CKRecord.ID`.
public struct CloudDataAccountIdentifier: RawRepresentable, Sendable, Hashable, Codable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

/// A signed-in account transition that requires an application data policy.
///
/// The stack deliberately does not decide whether retained local rows belong
/// to the new account. It suspends transport until the application explicitly
/// resumes after applying its keep, delete, or migration policy.
public enum CloudDataAccountChange: Sendable, Hashable, Codable {
  /// An account became available after no account was present.
  case signIn(current: CloudDataAccountIdentifier)

  /// The previous account signed out.
  case signOut(previous: CloudDataAccountIdentifier)

  /// One account was replaced by another account.
  case switchAccounts(
    previous: CloudDataAccountIdentifier,
    current: CloudDataAccountIdentifier
  )
}

/// The stable owner component of a custom record-zone identity.
public enum CloudDataZoneOwner: Sendable, Hashable, Codable {
  /// The signed-in CloudKit user represented by CloudKit's default owner name.
  case currentUser

  /// A concrete owner returned for a shared database zone.
  case named(String)
}

/// A transport-neutral custom record-zone identity.
public struct CloudDataZoneID: Sendable, Hashable, Codable {
  /// The stable custom-zone name.
  public let zoneName: String

  /// The owner component needed to route private and shared zones exactly.
  public let owner: CloudDataZoneOwner

  public init(zoneName: String, owner: CloudDataZoneOwner = .currentUser) {
    self.zoneName = zoneName
    self.owner = owner
  }
}

/// The complete remote route associated with one local store.
public struct CloudDataRemoteZone: Sendable, Hashable, Codable {
  /// The private or shared database containing the zone.
  public let databaseScope: CloudDataDatabaseScope

  /// The exact custom-zone identity inside that database.
  public let zoneID: CloudDataZoneID

  public init(
    databaseScope: CloudDataDatabaseScope,
    zoneID: CloudDataZoneID
  ) {
    self.databaseScope = databaseScope
    self.zoneID = zoneID
  }
}

/// The local persistence location for one store.
public enum CloudDataStoreLocation: Sendable, Hashable {
  /// A process-lifetime store used by previews and deterministic tests.
  case inMemory

  /// A durable SQLite-backed store at the supplied file URL.
  case file(URL)
}

/// Configuration for one stable ModelContainer and its remote custom zone.
public struct CloudDataStoreConfiguration: Sendable, Hashable {
  /// The consumer's stable identity for the local store.
  public let id: CloudDataStoreID

  /// The process-lifetime or durable local persistence location.
  public let location: CloudDataStoreLocation

  /// The one exact remote zone represented by this local store.
  public let remoteZone: CloudDataRemoteZone

  public init(
    id: CloudDataStoreID,
    location: CloudDataStoreLocation,
    remoteZone: CloudDataRemoteZone
  ) {
    self.id = id
    self.location = location
    self.remoteZone = remoteZone
  }
}

/// Why CloudKit reports that a previously-known remote zone disappeared.
public enum CloudDataRemoteZoneRemovalReason: String, Sendable, Hashable, Codable {
  /// The zone owner deleted the zone.
  case deleted

  /// CloudKit purged an inaccessible or revoked shared zone.
  case purged

  /// Encrypted data was reset for the account.
  case encryptedDataReset

  /// A future SDK supplied a reason this package does not yet recognize.
  case unknown
}

/// The bounded package response to a consumer's local-store repair policy.
public enum CloudDataLocalStoreOpenRecoveryAction: Sendable, Hashable {
  /// Surface the original open failure without retrying.
  case decline

  /// Retry the exact local configuration once and preserve transport tokens.
  case retry

  /// Retry once and invalidate package-owned engine tokens for a full refetch.
  case retryAndInvalidateTransportState
}

/// A closure-backed directory joining consumer store discovery to the stack.
///
/// Known stores open synchronously with the stack. The materializer is invoked
/// only when CloudKit discovers an otherwise unknown zone, leaving catalogs,
/// paths, and domain ownership in the consuming first-party module.
public struct CloudDataStoreDirectory: Sendable {
  /// Resolves an unknown remote zone into an application-owned local store.
  public typealias RemoteStoreMaterializer =
    @Sendable (CloudDataRemoteZone) async throws -> CloudDataStoreConfiguration?

  /// Applies application policy after CloudKit removes a known remote zone.
  public typealias RemoteZoneRemovalHandler =
    @Sendable (CloudDataRemoteZone, CloudDataRemoteZoneRemovalReason) async -> Void

  /// Repairs one failed local store open and selects the bounded retry action.
  public typealias LocalStoreOpenFailureRecovery =
    @Sendable (CloudDataStoreConfiguration, CloudDataStackSetupError) throws ->
    CloudDataLocalStoreOpenRecoveryAction

  /// Supplies the synchronization boundary for one application store.
  public typealias StoreCoordinationProvider =
    @Sendable (CloudDataStoreID) -> CloudDataStoreCoordination

  /// Stores that must be locally ready when the stack initializer returns.
  public let knownStores: [CloudDataStoreConfiguration]

  /// Directory containing versioned CKSyncEngine state envelopes.
  public let engineStateDirectoryURL: URL

  private let remoteStoreMaterializer: RemoteStoreMaterializer
  private let remoteZoneRemovalHandler: RemoteZoneRemovalHandler
  private let localStoreOpenFailureRecovery: LocalStoreOpenFailureRecovery
  private let storeCoordinationProvider: StoreCoordinationProvider

  public init(
    knownStores: [CloudDataStoreConfiguration],
    engineStateDirectoryURL: URL,
    materializeStoreForRemoteZone: @escaping RemoteStoreMaterializer = { _ in nil },
    handleRemoteZoneRemoval: @escaping RemoteZoneRemovalHandler = { _, _ in },
    recoverLocalStoreOpenFailure: @escaping LocalStoreOpenFailureRecovery = { _, _ in
      .decline
    },
    coordinationForStore: @escaping StoreCoordinationProvider = { _ in .processLocal }
  ) {
    self.knownStores = knownStores
    self.engineStateDirectoryURL = engineStateDirectoryURL
    self.remoteStoreMaterializer = materializeStoreForRemoteZone
    self.remoteZoneRemovalHandler = handleRemoteZoneRemoval
    self.localStoreOpenFailureRecovery = recoverLocalStoreOpenFailure
    self.storeCoordinationProvider = coordinationForStore
  }

  func materializeStore(
    for remoteZone: CloudDataRemoteZone
  ) async throws -> CloudDataStoreConfiguration? {
    try await remoteStoreMaterializer(remoteZone)
  }

  func notifyRemoteZoneRemoval(
    _ remoteZone: CloudDataRemoteZone,
    reason: CloudDataRemoteZoneRemovalReason
  ) async {
    await remoteZoneRemovalHandler(remoteZone, reason)
  }

  /// Gives the consumer one opportunity to repair an exact local store.
  ///
  /// The returned action can request one exact retry and, when local content
  /// was reset, invalidation of package-owned transport tokens. The package
  /// never deletes consumer data itself; reset, migration, and backup policy
  /// remain owned by the directory provider.
  func recoverLocalStoreOpenFailure(
    configuration: CloudDataStoreConfiguration,
    error: CloudDataStackSetupError
  ) throws -> CloudDataLocalStoreOpenRecoveryAction {
    try localStoreOpenFailureRecovery(configuration, error)
  }

  func coordination(for storeID: CloudDataStoreID) -> CloudDataStoreCoordination {
    storeCoordinationProvider(storeID)
  }
}

/// Selects either a real CloudKit transport or a deliberately disabled one.
public struct CloudDataTransportConfiguration: Sendable {
  enum Storage: Sendable {
    case offline
    case cloudKit(
      containerIdentifier: String,
      databaseScopes: Set<CloudDataDatabaseScope>,
      subscriptionIDs: [CloudDataDatabaseScope: CloudDataSubscriptionID],
      automaticallySync: Bool
    )
  }

  let storage: Storage

  /// Disables remote transport without changing the local stack shape.
  public static let offline = Self(storage: .offline)

  /// Uses one CKSyncEngine for each selected private/shared database.
  public static func cloudKit(
    containerIdentifier: String,
    databaseScopes: Set<CloudDataDatabaseScope>,
    subscriptionIDs: [CloudDataDatabaseScope: CloudDataSubscriptionID] = [:],
    automaticallySync: Bool = true
  ) -> Self {
    Self(
      storage: .cloudKit(
        containerIdentifier: containerIdentifier,
        databaseScopes: databaseScopes,
        subscriptionIDs: subscriptionIDs,
        automaticallySync: automaticallySync
      )
    )
  }
}

/// Fail-fast setup errors that prevent a safe local stack from being opened.
public enum CloudDataStackSetupError: Error, Sendable, Equatable {
  /// A store ID must be a stable nonempty consumer value.
  case emptyStoreID

  /// A custom zone name cannot be empty.
  case emptyZoneName(storeID: CloudDataStoreID)

  /// A concrete shared-zone owner name cannot be empty.
  case emptyZoneOwner(storeID: CloudDataStoreID)

  /// A shared database route must identify the concrete zone owner.
  case sharedZoneRequiresNamedOwner(storeID: CloudDataStoreID)

  /// Two configurations declared the same local store ID.
  case duplicateStoreID(CloudDataStoreID)

  /// Two local stores attempted to own the same exact remote route.
  case duplicateRemoteZone(CloudDataRemoteZone)

  /// Two store IDs attempted to open the same durable store file.
  case duplicateStoreFileURL(URL)

  /// The unknown-zone callback returned a store for another route.
  case remoteMaterializerReturnedMismatchedZone(
    expected: CloudDataRemoteZone,
    actual: CloudDataRemoteZone
  )

  /// A CloudKit transport requires a nonempty container identifier.
  case emptyContainerIdentifier

  /// A CloudKit transport must select private, shared, or both.
  case noDatabaseScopes

  /// A consumer-supplied silent subscription identifier cannot be empty.
  case emptySubscriptionID(scope: CloudDataDatabaseScope)

  /// A subscription identifier must target one of the enabled databases.
  case subscriptionIDForDisabledScope(scope: CloudDataDatabaseScope)

  /// A CloudKit schema containing asset slots requires consumer filesystem
  /// hooks before transport can start.
  case assetStoreRequired

  /// A known store cannot be synchronized by the selected engine scopes.
  case storeScopeNotEnabled(
    storeID: CloudDataStoreID,
    scope: CloudDataDatabaseScope
  )

  /// SwiftData could not open the configured local store.
  case localStoreOpenFailed(storeID: CloudDataStoreID, message: String)
}

/// Errors returned by explicit transport commands.
public enum CloudDataTransportOperationError: LocalizedError, Sendable, Equatable {
  /// The stack intentionally uses the offline transport.
  case offline

  /// `start()` has not constructed the configured engines yet.
  case notStarted

  /// The application must resolve retained local data before transport resumes.
  case accountChangeRequiresResolution(CloudDataAccountChange)

  /// The command failed after being translated out of CloudKit SDK types.
  case failed(CloudDataErrorSummary)

  /// Preserves actionable transport details when a consumer displays `localizedDescription`.
  public var errorDescription: String? {
    switch self {
    case .offline:
      "iCloud synchronization is disabled for this library."
    case .notStarted:
      "iCloud synchronization has not started yet."
    case .accountChangeRequiresResolution(let change):
      switch change {
      case .signIn:
        "Confirm this iCloud account before syncing the local library."
      case .signOut:
        "Sign in to iCloud to resume syncing. Your local library remains available."
      case .switchAccounts:
        "Confirm the new iCloud account before syncing the local library."
      }
    case .failed(let summary):
      summary.message
    }
  }
}
