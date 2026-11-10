import CloudKitData
import SwiftData

/// Immutable generated registrations shared by isolated model contexts.
///
/// Macro-generated closures capture no mutable state. Each operation receives
/// the actor-owned model/context explicitly and is invoked synchronously on
/// that owner. The unchecked conformance documents this narrow transfer rule.
struct CloudDataModelRegistry: @unchecked Sendable {
  let registrationsByRecordType: [String: CloudModelRegistration]
  let registrationsByModelType: [ObjectIdentifier: CloudModelRegistration]
  let descriptorsByRecordType: [String: CloudModelDescriptor]

  init(schema: CloudDataSchema) {
    self.registrationsByRecordType = Dictionary(
      uniqueKeysWithValues: schema.registrations.map {
        ($0.descriptor.recordType, $0)
      }
    )
    self.registrationsByModelType = Dictionary(
      uniqueKeysWithValues: schema.registrations.map {
        (ObjectIdentifier($0.modelType), $0)
      }
    )
    self.descriptorsByRecordType = Dictionary(
      uniqueKeysWithValues: schema.registrations.map {
        ($0.descriptor.recordType, $0.descriptor)
      }
    )
  }

  func registration<Model: CloudSyncedModel>(
    for modelType: Model.Type
  ) -> CloudModelRegistration? {
    registrationsByModelType[ObjectIdentifier(modelType)]
  }

  func registration(
    for modelType: any PersistentModel.Type
  ) -> CloudModelRegistration? {
    registrationsByModelType[ObjectIdentifier(modelType)]
  }
}
