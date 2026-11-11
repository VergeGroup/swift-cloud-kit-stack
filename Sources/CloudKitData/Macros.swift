import SwiftData

/// Declares an application-owned SwiftData model as one synchronized record
/// type.
///
/// The macro reads only source-written properties. It generates immutable
/// schema metadata and private field-mapping helpers without replacing
/// SwiftData's storage or accessors.
@attached(
  member,
  names:
    named(cloudModelRegistration),
  named(_CloudDecodedValues),
  named(_decodeCloudRecordSnapshot(_:)),
  named(init(_cloudRecordSnapshot:)),
  named(_cloudRecordSnapshot()),
  named(_applyCloudRecordSnapshot(_:))
)
@attached(extension, conformances: CloudSyncedModel)
public macro CloudSynced(recordType: StaticString, zoneDomain: StaticString) =
  #externalMacro(
    module: "CloudKitDataMacros",
    type: "CloudSyncedMacro"
  )

/// Marks a primitive stored property as one synchronized user field.
///
/// The stable field key is always explicit and must be a string literal. This
/// marker generates no accessor or backing storage.
@attached(peer)
public macro CloudField(_ key: StaticString) =
  #externalMacro(
    module: "CloudKitDataMacros",
    type: "CloudMarkerMacro"
  )

/// One primitive storage component of a native CloudKit location field.
public enum CloudLocationComponent: Sendable, Hashable {
  /// The latitude column, expressed in degrees.
  case latitude

  /// The longitude column, expressed in degrees.
  case longitude
}

/// Groups two source-written `Double` columns into one native location field.
///
/// The same explicit field key must appear once with `.latitude` and once with
/// `.longitude`. Both properties remain ordinary queryable SwiftData columns;
/// generated mapping combines them only in the transport-neutral snapshot.
@attached(peer)
public macro CloudLocation(
  _ key: StaticString,
  component: CloudLocationComponent
) =
  #externalMacro(
    module: "CloudKitDataMacros",
    type: "CloudMarkerMacro"
  )

/// Marks a String record-name property as one synchronized to-one
/// relationship.
///
/// The stable wire key, target model, local optional relationship, and
/// resolution requirement are always explicit. The typed writable key path
/// lets Swift reject target/local shape mismatches before macro expansion.
@attached(peer)
public macro CloudRelationship<Root: PersistentModel, Target: PersistentModel>(
  _ key: StaticString,
  target: Target.Type,
  local: ReferenceWritableKeyPath<Root, Target?>,
  requirement: CloudRelationshipRequirement
) =
  #externalMacro(
    module: "CloudKitDataMacros",
    type: "CloudMarkerMacro"
  )

/// Marks a read-only computed `CloudAssetSlot` as one CKAsset-backed field.
///
/// The stable field key is always explicit. The computed property supplies a
/// CK-free logical identifier; it does not persist a `CKAsset` or file URL.
@attached(peer)
public macro CloudAsset(_ key: StaticString) =
  #externalMacro(
    module: "CloudKitDataMacros",
    type: "CloudMarkerMacro"
  )

/// Marks the stored UUID or String used as the remote record name.
///
/// Record identity is not duplicated into the user-field dictionary. This
/// marker generates no accessor or backing storage.
@attached(peer)
public macro CloudRecordName() =
  #externalMacro(
    module: "CloudKitDataMacros",
    type: "CloudMarkerMacro"
  )

/// Marks a SwiftData-persisted property that is intentionally local-only.
///
/// A source default is required so generated remote materialization can
/// initialize the property without adding an application-specific factory.
@attached(peer)
public macro CloudLocal() =
  #externalMacro(
    module: "CloudKitDataMacros",
    type: "CloudMarkerMacro"
  )
