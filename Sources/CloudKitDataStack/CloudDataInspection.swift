import Foundation

/// The current CloudKit account identity without exposing CloudKit SDK types.
public enum CloudDataAccountIdentifierLookup: Sendable, Hashable {
  /// CloudKit is available and resolved the account's opaque record identity.
  case available(CloudDataAccountIdentifier)

  /// No iCloud account is currently available to CloudKit.
  case signedOut

  /// Device or account policy prevents this application from using iCloud.
  case restricted

  /// CloudKit could not produce a stable answer yet.
  case temporarilyUnavailable
}

/// Record totals observed by an isolated remote-zone inspection.
///
/// The inspection uses its own disposable change token. It never advances a
/// CKSyncEngine token or mutates the corresponding local SwiftData store.
public struct CloudDataRemoteRecordCounts: Sendable, Hashable {
  /// Number of currently-present records grouped by CloudKit record type.
  public let countsByRecordType: [String: Int]

  public init(countsByRecordType: [String: Int]) {
    self.countsByRecordType = countsByRecordType
  }

  /// Total number of records observed across every record type.
  public var totalCount: Int {
    countsByRecordType.values.reduce(0, +)
  }
}
