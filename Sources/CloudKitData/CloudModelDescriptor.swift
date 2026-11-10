import SwiftData

/// The source type used to derive a stable remote record name.
public enum CloudRecordNameKind: String, Sendable, Hashable {
  /// Convert a UUID to and from its canonical string representation.
  case uuid

  /// Preserve an application-provided String identity verbatim.
  case string
}

/// An immutable description of one synchronized user field.
public struct CloudFieldDescriptor: Sendable, Hashable {
  /// The stable wire key stored by the remote record.
  public let key: String

  /// The closed field category accepted for the field.
  public let kind: CloudFieldKind

  /// Whether an absent remote value maps to `nil` instead of a validation
  /// error.
  public let isOptional: Bool

  public init(key: String, kind: CloudFieldKind, isOptional: Bool) {
    self.key = key
    self.kind = kind
    self.isOptional = isOptional
  }
}

/// The remote representation used for one synchronized relationship.
///
/// Record-name storage preserves the existing Tinycurve wire shape. Native
/// CloudKit references require additional zone and save-order semantics and
/// will be introduced as a separate explicit mode if needed.
public enum CloudRelationshipStorage: String, Sendable, Hashable {
  /// Store the target's stable remote record name as a String field.
  case recordName
}

/// Whether a relationship identity may be absent from a remote record.
public enum CloudRelationshipRequirement: String, Sendable, Hashable {
  /// Both the remote identity and local relationship may be absent.
  case optional

  /// The remote identity is required, while local resolution may temporarily
  /// remain nil until an out-of-order target arrives.
  case eventuallyRequired
}

/// An immutable description of one synchronized to-one relationship.
public struct CloudRelationshipDescriptor: Sendable, Hashable {
  /// The stable wire key containing the target record name.
  public let key: String

  /// The fully-qualified Swift target type used for schema registration.
  public let targetModelTypeName: String

  /// The source-written local SwiftData relationship property.
  public let localPropertyName: String

  /// The explicit remote representation for this relationship.
  public let storage: CloudRelationshipStorage

  /// The required/optional import and repair contract.
  public let requirement: CloudRelationshipRequirement

  /// Whether the raw record-name property is optional.
  public let isOptional: Bool

  public init<Target: PersistentModel>(
    key: String,
    targetModelType: Target.Type,
    localPropertyName: String,
    storage: CloudRelationshipStorage,
    requirement: CloudRelationshipRequirement,
    isOptional: Bool
  ) {
    self.key = key
    self.targetModelTypeName = String(reflecting: targetModelType)
    self.localPropertyName = localPropertyName
    self.storage = storage
    self.requirement = requirement
    self.isOptional = isOptional
  }
}

/// An immutable generated manifest for one application-owned SwiftData model.
public struct CloudModelDescriptor: Sendable, Hashable {
  /// The stable remote record type.
  public let recordType: String

  /// The logical graph partition shared by models that may relate to one
  /// another. Concrete database scope, zone name, and owner remain runtime
  /// store configuration.
  public let zoneDomain: String

  /// The conversion rule used for the record identity property.
  public let recordNameKind: CloudRecordNameKind

  /// User fields in deterministic generated order.
  ///
  /// Composite fields are emitted after directly stored fields. Consumers must
  /// address fields by key rather than relying on this collection's order.
  public let fields: [CloudFieldDescriptor]

  /// To-one relationship identities in deterministic source declaration
  /// order.
  public let relationships: [CloudRelationshipDescriptor]

  /// CKAsset-backed fields in deterministic source declaration order.
  public let assets: [CloudAssetDescriptor]

  /// Every wire field consumed by the transport adapter.
  ///
  /// Relationship identities use String storage but remain separately
  /// classified in `relationships` for validation and repair.
  public var wireFields: [CloudFieldDescriptor] {
    fields
      + relationships.map { relationship in
        CloudFieldDescriptor(
          key: relationship.key,
          kind: .string,
          isOptional: relationship.isOptional
        )
      }
  }

  public init(
    recordType: String,
    zoneDomain: String,
    recordNameKind: CloudRecordNameKind,
    fields: [CloudFieldDescriptor],
    relationships: [CloudRelationshipDescriptor],
    assets: [CloudAssetDescriptor] = []
  ) {
    self.recordType = recordType
    self.zoneDomain = zoneDomain
    self.recordNameKind = recordNameKind
    self.fields = fields
    self.relationships = relationships
    self.assets = assets
  }
}
