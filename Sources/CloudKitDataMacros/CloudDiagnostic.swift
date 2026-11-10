import SwiftDiagnostics

struct CloudDiagnostic: DiagnosticMessage {
  let message: String
  let diagnosticID: MessageID
  let severity: DiagnosticSeverity = .error

  static let classOnly = CloudDiagnostic(
    message: "@CloudSynced can only be attached to a class",
    diagnosticID: .init(domain: "CloudKitData", id: "class-only")
  )

  static let finalClassRequired = CloudDiagnostic(
    message: "@CloudSynced requires a final class",
    diagnosticID: .init(domain: "CloudKitData", id: "final-class-required")
  )

  static let recordTypeRequired = CloudDiagnostic(
    message: "@CloudSynced requires recordType: with a string literal",
    diagnosticID: .init(domain: "CloudKitData", id: "record-type-required")
  )

  static let recordTypeLiteralRequired = CloudDiagnostic(
    message: "@CloudSynced recordType must be a string literal",
    diagnosticID: .init(domain: "CloudKitData", id: "record-type-literal-required")
  )

  static let emptyRecordType = CloudDiagnostic(
    message: "@CloudSynced recordType cannot be empty",
    diagnosticID: .init(domain: "CloudKitData", id: "empty-record-type")
  )

  static let zoneDomainRequired = CloudDiagnostic(
    message: "@CloudSynced requires zoneDomain: with a string literal",
    diagnosticID: .init(domain: "CloudKitData", id: "zone-domain-required")
  )

  static let zoneDomainLiteralRequired = CloudDiagnostic(
    message: "@CloudSynced zoneDomain must be a string literal",
    diagnosticID: .init(domain: "CloudKitData", id: "zone-domain-literal-required")
  )

  static let emptyZoneDomain = CloudDiagnostic(
    message: "@CloudSynced zoneDomain cannot be empty",
    diagnosticID: .init(domain: "CloudKitData", id: "empty-zone-domain")
  )

  static let invalidCloudSyncedArguments = CloudDiagnostic(
    message: "@CloudSynced requires recordType: followed by zoneDomain:",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-cloud-synced-arguments")
  )

  static let missingIdentity = CloudDiagnostic(
    message: "@CloudSynced requires exactly one @CloudRecordName property",
    diagnosticID: .init(domain: "CloudKitData", id: "missing-identity")
  )

  static let duplicateIdentity = CloudDiagnostic(
    message: "@CloudSynced allows only one @CloudRecordName property",
    diagnosticID: .init(domain: "CloudKitData", id: "duplicate-identity")
  )

  static let invalidIdentityType = CloudDiagnostic(
    message: "@CloudRecordName must be a nonoptional UUID or String",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-identity-type")
  )

  static let invalidIdentityArguments = CloudDiagnostic(
    message: "@CloudRecordName does not accept arguments",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-identity-arguments")
  )

  static let invalidLocalArguments = CloudDiagnostic(
    message: "@CloudLocal does not accept arguments",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-local-arguments")
  )

  static let invalidFieldArguments = CloudDiagnostic(
    message: "@CloudField accepts exactly one unlabeled field-key literal and no codec",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-field-arguments")
  )

  static let fieldKeyLiteralRequired = CloudDiagnostic(
    message: "@CloudField key must be a string literal",
    diagnosticID: .init(domain: "CloudKitData", id: "field-key-literal-required")
  )

  static let emptyFieldKey = CloudDiagnostic(
    message: "@CloudField key cannot be empty",
    diagnosticID: .init(domain: "CloudKitData", id: "empty-field-key")
  )

  static let invalidLocationArguments = CloudDiagnostic(
    message:
      "@CloudLocation requires one field-key literal followed by component: .latitude or .longitude",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-location-arguments")
  )

  static let locationKeyLiteralRequired = CloudDiagnostic(
    message: "@CloudLocation key must be a string literal",
    diagnosticID: .init(domain: "CloudKitData", id: "location-key-literal-required")
  )

  static let emptyLocationKey = CloudDiagnostic(
    message: "@CloudLocation key cannot be empty",
    diagnosticID: .init(domain: "CloudKitData", id: "empty-location-key")
  )

  static let invalidLocationComponent = CloudDiagnostic(
    message: "@CloudLocation component must be .latitude or .longitude",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-location-component")
  )

  static func invalidLocationComponentType(_ type: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "@CloudLocation must be attached to Double or Double?, not '\(type)'",
      diagnosticID: .init(domain: "CloudKitData", id: "invalid-location-component-type")
    )
  }

  static func duplicateLocationComponent(
    key: String,
    component: String
  ) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "Cloud location '\(key)' declares more than one .\(component) component",
      diagnosticID: .init(domain: "CloudKitData", id: "duplicate-location-component")
    )
  }

  static func missingLocationComponent(
    key: String,
    component: String
  ) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "Cloud location '\(key)' is missing its .\(component) component",
      diagnosticID: .init(domain: "CloudKitData", id: "missing-location-component")
    )
  }

  static func locationOptionalityMismatch(_ key: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "Cloud location '\(key)' components must have matching optionality",
      diagnosticID: .init(domain: "CloudKitData", id: "location-optionality-mismatch")
    )
  }

  static let invalidAssetArguments = CloudDiagnostic(
    message: "@CloudAsset accepts exactly one unlabeled field-key literal",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-asset-arguments")
  )

  static let assetKeyLiteralRequired = CloudDiagnostic(
    message: "@CloudAsset key must be a string literal",
    diagnosticID: .init(domain: "CloudKitData", id: "asset-key-literal-required")
  )

  static let emptyAssetKey = CloudDiagnostic(
    message: "@CloudAsset key cannot be empty",
    diagnosticID: .init(domain: "CloudKitData", id: "empty-asset-key")
  )

  static let immutableAssetSlot = CloudDiagnostic(
    message: "@CloudAsset slot must be declared as a computed var",
    diagnosticID: .init(domain: "CloudKitData", id: "immutable-asset-slot")
  )

  static func explicitAssetSlotTypeRequired(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "@CloudAsset property '\(name)' needs an explicit CloudAssetSlot type",
      diagnosticID: .init(domain: "CloudKitData", id: "explicit-asset-slot-type-required")
    )
  }

  static func invalidAssetSlotType(_ type: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "@CloudAsset computed property must have type CloudAssetSlot, not '\(type)'",
      diagnosticID: .init(domain: "CloudKitData", id: "invalid-asset-slot-type")
    )
  }

  static func storedCloudAsset(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "@CloudAsset property '\(name)' must be computed, not stored",
      diagnosticID: .init(domain: "CloudKitData", id: "stored-cloud-asset")
    )
  }

  static func writableAssetSlot(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "@CloudAsset property '\(name)' must be read-only",
      diagnosticID: .init(domain: "CloudKitData", id: "writable-asset-slot")
    )
  }

  static let immutableProperty = CloudDiagnostic(
    message: "synchronized stored properties must be declared with var",
    diagnosticID: .init(domain: "CloudKitData", id: "immutable-property")
  )

  static func duplicateWireKey(_ key: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "duplicate Cloud wire key '\(key)'",
      diagnosticID: .init(domain: "CloudKitData", id: "duplicate-wire-key")
    )
  }

  static let invalidRelationshipArguments = CloudDiagnostic(
    message:
      "@CloudRelationship requires an explicit key, target:, local:, and requirement:",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-relationship-arguments")
  )

  static let relationshipKeyLiteralRequired = CloudDiagnostic(
    message: "@CloudRelationship key must be a string literal",
    diagnosticID: .init(domain: "CloudKitData", id: "relationship-key-literal-required")
  )

  static let emptyRelationshipKey = CloudDiagnostic(
    message: "@CloudRelationship key cannot be empty",
    diagnosticID: .init(domain: "CloudKitData", id: "empty-relationship-key")
  )

  static let invalidRelationshipIdentityType = CloudDiagnostic(
    message: "@CloudRelationship must be attached to a String or String? property",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-relationship-identity-type")
  )

  static let relationshipTargetTypeRequired = CloudDiagnostic(
    message: "@CloudRelationship target must be a concrete model type ending in .self",
    diagnosticID: .init(domain: "CloudKitData", id: "relationship-target-type-required")
  )

  static func relationshipLocalKeyPathRequired(_ sourceType: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message:
        "@CloudRelationship local must be a direct key path rooted at \(sourceType)",
      diagnosticID: .init(domain: "CloudKitData", id: "relationship-local-key-path-required")
    )
  }

  static let invalidRelationshipRequirement = CloudDiagnostic(
    message: "@CloudRelationship requirement must be .optional or .eventuallyRequired",
    diagnosticID: .init(domain: "CloudKitData", id: "invalid-relationship-requirement")
  )

  static func relationshipRequirementTypeMismatch(_ requirement: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message:
        "@CloudRelationship requirement .\(requirement) does not match the raw String optionality",
      diagnosticID: .init(domain: "CloudKitData", id: "relationship-requirement-type-mismatch")
    )
  }

  static func duplicateRelationshipLocalProperty(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "multiple @CloudRelationship properties target local relationship '\(name)'",
      diagnosticID: .init(domain: "CloudKitData", id: "duplicate-relationship-local-property")
    )
  }

  static func relationshipLocalPropertyMissing(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "@CloudRelationship local property '\(name)' is not declared",
      diagnosticID: .init(domain: "CloudKitData", id: "relationship-local-property-missing")
    )
  }

  static func relationshipLocalPropertyRequiresRelationship(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "@CloudRelationship local property '\(name)' must use @Relationship",
      diagnosticID: .init(
        domain: "CloudKitData",
        id: "relationship-local-property-requires-relationship"
      )
    )
  }

  static func relationshipLocalPropertyTypeMismatch(
    name: String,
    targetType: String
  ) -> CloudDiagnostic {
    CloudDiagnostic(
      message:
        "@CloudRelationship local property '\(name)' must be a mutable \(targetType)?",
      diagnosticID: .init(domain: "CloudKitData", id: "relationship-local-property-type-mismatch")
    )
  }

  static func unsupportedType(_ type: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "@CloudField does not support stored type '\(type)'",
      diagnosticID: .init(domain: "CloudKitData", id: "unsupported-type")
    )
  }

  static func unclassified(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "persisted property '\(name)' must be explicitly classified",
      diagnosticID: .init(domain: "CloudKitData", id: "unclassified-property")
    )
  }

  static func multipleClassifications(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "persisted property '\(name)' has multiple synchronization classifications",
      diagnosticID: .init(domain: "CloudKitData", id: "multiple-classifications")
    )
  }

  static func defaultRequired(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message:
        "local, relationship, or transient property '\(name)' needs a source default for generated materialization",
      diagnosticID: .init(domain: "CloudKitData", id: "default-required")
    )
  }

  static func explicitTypeRequired(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "stored property '\(name)' needs an explicit type annotation",
      diagnosticID: .init(domain: "CloudKitData", id: "explicit-type-required")
    )
  }

  static func computedCloudField(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "computed property '\(name)' cannot be a Cloud field",
      diagnosticID: .init(domain: "CloudKitData", id: "computed-cloud-field")
    )
  }

  static func computedLocationComponent(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "@CloudLocation component '\(name)' must be a stored property",
      diagnosticID: .init(domain: "CloudKitData", id: "computed-location-component")
    )
  }

  static func computedIdentity(_ name: String) -> CloudDiagnostic {
    CloudDiagnostic(
      message: "computed property '\(name)' cannot be the Cloud record name",
      diagnosticID: .init(domain: "CloudKitData", id: "computed-identity")
    )
  }
}
