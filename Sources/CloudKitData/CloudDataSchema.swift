import Foundation
import SwiftData

/// One model list that produces both the SwiftData schema and generated wire
/// registrations.
///
/// The listed concrete models are supplied by the consuming application's
/// first-party module; this package defines no application model classes.
public struct CloudDataSchema {
  /// Application-owned model types in deterministic consumer-provided order.
  public let modelTypes: [any PersistentModel.Type]

  /// Registrations in deterministic consumer-provided order.
  public let registrations: [CloudModelRegistration]

  /// The matching SwiftData schema built from the same model list.
  public let swiftDataSchema: Schema

  /// Explicit import-behavior generation used to invalidate transport tokens.
  ///
  /// This remains independent of the generated wire fingerprint because an
  /// import policy can change while the record fields stay identical.
  public let replayGeneration: Int

  /// The one logical relationship graph declared by synchronized models.
  ///
  /// A schema containing no synchronized models has no zone domain. Concrete
  /// CloudKit routing remains on each `CloudDataStoreConfiguration`.
  public let zoneDomain: String?

  /// A deterministic fingerprint of record types, identities, and fields.
  public let wireSchemaFingerprint: String

  /// The SwiftData schema version supplied by the consumer.
  public let version: Schema.Version

  private let registrationsByRecordType: [String: CloudModelRegistration]

  public init(
    replayGeneration: Int = 1,
    models: [any PersistentModel.Type],
    version: Schema.Version = .init(1, 0, 0)
  ) throws {
    guard replayGeneration >= 0 else {
      throw CloudDataSchemaError.invalidReplayGeneration(replayGeneration)
    }

    var registrations: [CloudModelRegistration] = []
    var modelIdentifiers = Set<ObjectIdentifier>()
    var registrationsByRecordType: [String: CloudModelRegistration] = [:]
    var registrationsByModelTypeName: [String: CloudModelRegistration] = [:]

    for model in models {
      let modelIdentifier = ObjectIdentifier(model)
      guard modelIdentifiers.insert(modelIdentifier).inserted else {
        throw CloudDataSchemaError.duplicateModelType(
          String(reflecting: model)
        )
      }
      if let synchronizedModel = model as? any CloudSyncedModel.Type {
        let registration = synchronizedModel.cloudModelRegistration
        guard ObjectIdentifier(registration.modelType) == modelIdentifier else {
          throw CloudDataSchemaError.registrationModelTypeMismatch(
            listed: String(reflecting: model),
            registered: String(reflecting: registration.modelType)
          )
        }
        registrations.append(registration)
        registrationsByModelTypeName[String(reflecting: model)] = registration
      }
    }

    var zoneDomains = Set<String>()
    for registration in registrations {
      let descriptor = registration.descriptor
      guard descriptor.recordType.isEmpty == false else {
        throw CloudDataSchemaError.emptyRecordType(
          modelType: String(reflecting: registration.modelType)
        )
      }
      guard registrationsByRecordType[descriptor.recordType] == nil else {
        throw CloudDataSchemaError.duplicateRecordType(descriptor.recordType)
      }
      guard descriptor.zoneDomain.isEmpty == false else {
        throw CloudDataSchemaError.emptyZoneDomain(
          recordType: descriptor.recordType
        )
      }
      zoneDomains.insert(descriptor.zoneDomain)

      guard registration.relationships.map(\.descriptor) == descriptor.relationships else {
        throw CloudDataSchemaError.relationshipRegistrationMismatch(
          recordType: descriptor.recordType
        )
      }
      guard registration.assets.map(\.descriptor) == descriptor.assets else {
        throw CloudDataSchemaError.assetRegistrationMismatch(
          recordType: descriptor.recordType
        )
      }

      var fieldKeys = Set<String>()
      for field in descriptor.wireFields {
        guard field.key.isEmpty == false else {
          throw CloudDataSchemaError.emptyFieldKey(recordType: descriptor.recordType)
        }
        guard fieldKeys.insert(field.key).inserted else {
          throw CloudDataSchemaError.duplicateFieldKey(
            recordType: descriptor.recordType,
            key: field.key
          )
        }
      }
      for asset in descriptor.assets {
        guard asset.key.isEmpty == false else {
          throw CloudDataSchemaError.emptyFieldKey(recordType: descriptor.recordType)
        }
        guard fieldKeys.insert(asset.key).inserted else {
          throw CloudDataSchemaError.duplicateFieldKey(
            recordType: descriptor.recordType,
            key: asset.key
          )
        }
      }

      var localRelationshipNames = Set<String>()
      for (index, relationship) in descriptor.relationships.enumerated() {
        let operation = registration.relationships[index]
        guard
          ObjectIdentifier(operation.sourceModelType) == ObjectIdentifier(registration.modelType)
        else {
          throw CloudDataSchemaError.relationshipSourceModelTypeMismatch(
            recordType: descriptor.recordType,
            key: relationship.key
          )
        }
        guard
          String(reflecting: operation.targetModelType)
            == relationship.targetModelTypeName
        else {
          throw CloudDataSchemaError.relationshipTargetModelTypeMismatch(
            recordType: descriptor.recordType,
            key: relationship.key
          )
        }
        guard relationship.localPropertyName.isEmpty == false else {
          throw CloudDataSchemaError.emptyRelationshipLocalProperty(
            recordType: descriptor.recordType,
            key: relationship.key
          )
        }
        guard localRelationshipNames.insert(relationship.localPropertyName).inserted else {
          throw CloudDataSchemaError.duplicateRelationshipLocalProperty(
            recordType: descriptor.recordType,
            localPropertyName: relationship.localPropertyName
          )
        }
        let hasMatchingOptionality: Bool
        switch relationship.requirement {
        case .optional:
          hasMatchingOptionality = relationship.isOptional
        case .eventuallyRequired:
          hasMatchingOptionality = relationship.isOptional == false
        }
        guard hasMatchingOptionality else {
          throw CloudDataSchemaError.relationshipRequirementTypeMismatch(
            recordType: descriptor.recordType,
            key: relationship.key,
            requirement: relationship.requirement
          )
        }
      }

      var assetPropertyNames = Set<String>()
      for (index, asset) in descriptor.assets.enumerated() {
        let operation = registration.assets[index]
        guard
          ObjectIdentifier(operation.sourceModelType) == ObjectIdentifier(registration.modelType)
        else {
          throw CloudDataSchemaError.assetSourceModelTypeMismatch(
            recordType: descriptor.recordType,
            key: asset.key
          )
        }
        guard asset.propertyName.isEmpty == false else {
          throw CloudDataSchemaError.emptyAssetProperty(
            recordType: descriptor.recordType,
            key: asset.key
          )
        }
        guard assetPropertyNames.insert(asset.propertyName).inserted else {
          throw CloudDataSchemaError.duplicateAssetProperty(
            recordType: descriptor.recordType,
            propertyName: asset.propertyName
          )
        }
      }

      registrationsByRecordType[descriptor.recordType] = registration
    }

    for registration in registrations {
      let source = registration.descriptor
      for relationship in source.relationships {
        guard
          let target = registrationsByModelTypeName[
            relationship.targetModelTypeName
          ]
        else {
          throw CloudDataSchemaError.missingRelationshipTarget(
            sourceRecordType: source.recordType,
            key: relationship.key,
            targetModelType: relationship.targetModelTypeName
          )
        }
        guard target.descriptor.zoneDomain == source.zoneDomain else {
          throw CloudDataSchemaError.relationshipZoneDomainMismatch(
            sourceRecordType: source.recordType,
            key: relationship.key,
            sourceZoneDomain: source.zoneDomain,
            targetRecordType: target.descriptor.recordType,
            targetZoneDomain: target.descriptor.zoneDomain
          )
        }
      }
    }

    if zoneDomains.count > 1 {
      throw CloudDataSchemaError.mixedZoneDomains(zoneDomains.sorted())
    }

    self.modelTypes = models
    self.registrations = registrations
    self.swiftDataSchema = Schema(
      models,
      version: version
    )
    self.replayGeneration = replayGeneration
    self.zoneDomain = zoneDomains.first
    self.wireSchemaFingerprint = Self.makeWireSchemaFingerprint(
      registrations: registrations,
      registrationsByModelTypeName: registrationsByModelTypeName
    )
    self.version = version
    self.registrationsByRecordType = registrationsByRecordType
  }

  /// Returns the generated registration for a stable remote record type.
  public func registration(
    forRecordType recordType: String
  ) -> CloudModelRegistration? {
    registrationsByRecordType[recordType]
  }

  private static func makeWireSchemaFingerprint(
    registrations: [CloudModelRegistration],
    registrationsByModelTypeName: [String: CloudModelRegistration]
  ) -> String {
    let manifest =
      registrations
      .map(\.descriptor)
      .sorted { $0.recordType < $1.recordType }
      .map { descriptor in
        let fields = descriptor.fields
          .sorted { $0.key < $1.key }
          .map { field in
            "field:\(field.key):\(field.kind.rawValue):\(field.isOptional ? "optional" : "required")"
          }
          .joined(separator: ",")
        let relationships = descriptor.relationships
          .sorted { $0.key < $1.key }
          .map { relationship in
            let targetRecordType =
              registrationsByModelTypeName[relationship.targetModelTypeName]?
              .descriptor.recordType ?? relationship.targetModelTypeName
            return
              "relationship:\(relationship.key):\(targetRecordType):\(relationship.storage.rawValue):\(relationship.requirement.rawValue):\(relationship.isOptional ? "optional" : "required")"
          }
          .joined(separator: ",")
        let assets = descriptor.assets
          .sorted { $0.key < $1.key }
          .map { "asset:\($0.key)" }
          .joined(separator: ",")
        return
          "\(descriptor.recordType)|\(descriptor.zoneDomain)|\(descriptor.recordNameKind.rawValue)|\(fields)|\(relationships)|\(assets)"
      }
      .joined(separator: "\n")

    // FNV-1a is used for deterministic compatibility identity, not security.
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in manifest.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let hexadecimal = String(hash, radix: 16, uppercase: false)
    return String(repeating: "0", count: max(0, 16 - hexadecimal.count)) + hexadecimal
  }
}

/// Structural schema errors that remain validated even for manually-created
/// registrations.
public enum CloudDataSchemaError: Error, Sendable, Equatable {
  /// Replay generations are monotonic nonnegative compatibility values.
  case invalidReplayGeneration(Int)

  /// The same concrete SwiftData model type appears more than once.
  case duplicateModelType(String)

  /// A manually-authored conformance registered operations for another type.
  case registrationModelTypeMismatch(listed: String, registered: String)

  /// A registration contains an empty record type.
  case emptyRecordType(modelType: String)

  /// Two synchronized model types use the same stable record type.
  case duplicateRecordType(String)

  /// A synchronized descriptor contains no logical zone domain.
  case emptyZoneDomain(recordType: String)

  /// One initial schema attempted to combine multiple logical graphs.
  case mixedZoneDomains([String])

  /// A generated or manually-created field descriptor has an empty key.
  case emptyFieldKey(recordType: String)

  /// Two fields in one record manifest use the same stable key.
  case duplicateFieldKey(recordType: String, key: String)

  /// Generated relationship operations drifted from immutable descriptors.
  case relationshipRegistrationMismatch(recordType: String)

  /// Generated asset operations drifted from immutable descriptors.
  case assetRegistrationMismatch(recordType: String)

  /// A relationship operation was generated for another source model type.
  case relationshipSourceModelTypeMismatch(recordType: String, key: String)

  /// A relationship operation's target type disagrees with its descriptor.
  case relationshipTargetModelTypeMismatch(recordType: String, key: String)

  /// A relationship descriptor omitted the local property name.
  case emptyRelationshipLocalProperty(recordType: String, key: String)

  /// Two remote identities attempted to own one local relationship property.
  case duplicateRelationshipLocalProperty(
    recordType: String,
    localPropertyName: String
  )

  /// Required/optional metadata disagrees with raw String optionality.
  case relationshipRequirementTypeMismatch(
    recordType: String,
    key: String,
    requirement: CloudRelationshipRequirement
  )

  /// An asset operation was generated for another source model type.
  case assetSourceModelTypeMismatch(recordType: String, key: String)

  /// An asset descriptor omitted its computed property name.
  case emptyAssetProperty(recordType: String, key: String)

  /// Two asset keys attempted to identify one computed property.
  case duplicateAssetProperty(recordType: String, propertyName: String)

  /// A relationship target model was not registered in the same schema.
  case missingRelationshipTarget(
    sourceRecordType: String,
    key: String,
    targetModelType: String
  )

  /// A relationship crossed logical zone domains.
  case relationshipZoneDomainMismatch(
    sourceRecordType: String,
    key: String,
    sourceZoneDomain: String,
    targetRecordType: String,
    targetZoneDomain: String
  )
}
