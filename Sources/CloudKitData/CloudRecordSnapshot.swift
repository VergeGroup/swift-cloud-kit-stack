/// A transport-neutral snapshot of one synchronized application model.
///
/// This is one library-wide value representation, not a second authored model
/// type. Concrete SwiftData models remain owned by the consuming application.
public struct CloudRecordSnapshot: Sendable, Hashable {
  /// The stable identity represented by the remote record name.
  public let recordName: String

  /// Present user fields keyed by their explicit wire names.
  ///
  /// Optional values are omitted when `nil`; the dictionary never stores a
  /// separate null sentinel.
  public let fields: [String: CloudFieldValue]

  public init(recordName: String, fields: [String: CloudFieldValue]) {
    self.recordName = recordName
    self.fields = fields
  }
}

/// Validation failures produced while decoding a transport-neutral snapshot.
public enum CloudRecordSnapshotError: Error, Sendable, Equatable {
  /// A UUID-backed identity could not be reconstructed from the record name.
  case invalidRecordName(String)

  /// A fetched snapshot was routed to an existing model with another identity.
  case recordNameMismatch(expected: String, actual: String)

  /// A required value is absent or a present value has the wrong field
  /// category.
  case missingOrInvalidField(key: String, expected: CloudFieldKind)

  /// Exactly one component of an optional composite location is present.
  case incompleteLocation(key: String)

  /// Latitude or longitude is non-finite or outside its geographic range.
  case invalidLocation(key: String)
}
