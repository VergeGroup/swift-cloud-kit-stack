import SwiftData

/// The single public witness generated for a synchronized application model.
///
/// Concrete model declarations remain in the consuming first-party module.
/// Macro-generated private helpers provide the model-specific implementation
/// captured by this registration.
public protocol CloudSyncedModel: PersistentModel {
  static var cloudModelRegistration: CloudModelRegistration { get }
}

/// A type-erased registration for generated model mapping operations.
///
/// Registrations are intentionally not `Sendable`: SwiftData model instances
/// must stay on their owning model context or actor. Immutable descriptors and
/// `CloudRecordSnapshot` values can cross concurrency boundaries separately.
public struct CloudModelRegistration {
  /// The concrete application-owned SwiftData model type.
  public let modelType: any PersistentModel.Type

  /// The deterministic wire manifest generated from the model source.
  public let descriptor: CloudModelDescriptor

  /// Typed local relationship operations in source declaration order.
  public let relationships: [CloudRelationshipRegistration]

  /// Typed logical asset-slot operations in source declaration order.
  public let assets: [CloudAssetRegistration]

  private let makeSnapshotImplementation: (any PersistentModel) throws -> CloudRecordSnapshot
  private let applySnapshotImplementation: (CloudRecordSnapshot, any PersistentModel) throws -> Void
  private let materializeImplementation: (CloudRecordSnapshot) throws -> any PersistentModel
  private let fetchImplementation: (String, ModelContext) throws -> (any PersistentModel)?

  /// Creates the type-erased registration captured by generated code.
  ///
  /// Applications normally use `@CloudSynced` instead of calling this
  /// initializer directly.
  public init<Model: PersistentModel>(
    modelType: Model.Type,
    descriptor: CloudModelDescriptor,
    relationships: [CloudRelationshipRegistration] = [],
    assets: [CloudAssetRegistration] = [],
    fetch: @escaping (String, ModelContext) throws -> Model?,
    makeSnapshot: @escaping (Model) throws -> CloudRecordSnapshot,
    applySnapshot: @escaping (Model, CloudRecordSnapshot) throws -> Void,
    materialize: @escaping (CloudRecordSnapshot) throws -> Model
  ) {
    self.modelType = modelType
    self.descriptor = descriptor
    self.relationships = relationships
    self.assets = assets
    self.fetchImplementation = { recordName, context in
      try fetch(recordName, context)
    }

    let expectedModelType = String(reflecting: modelType)
    self.makeSnapshotImplementation = { model in
      guard let model = model as? Model else {
        throw CloudModelRegistrationError.modelTypeMismatch(
          expected: expectedModelType,
          actual: String(reflecting: Swift.type(of: model))
        )
      }
      return try makeSnapshot(model)
    }
    self.applySnapshotImplementation = { snapshot, model in
      guard let model = model as? Model else {
        throw CloudModelRegistrationError.modelTypeMismatch(
          expected: expectedModelType,
          actual: String(reflecting: Swift.type(of: model))
        )
      }
      try applySnapshot(model, snapshot)
    }
    self.materializeImplementation = { snapshot in
      try materialize(snapshot)
    }
  }

  /// Fetches the registered model with the stable remote record name.
  ///
  /// The generated implementation uses a typed SwiftData predicate so remote
  /// imports do not require a handwritten model router or a full-table scan.
  public func fetch(
    recordName: String,
    in context: ModelContext
  ) throws -> (any PersistentModel)? {
    try fetchImplementation(recordName, context)
  }

  /// Encodes one model into the transport-neutral representation.
  public func makeSnapshot(
    from model: any PersistentModel
  ) throws -> CloudRecordSnapshot {
    try makeSnapshotImplementation(model)
  }

  /// Merges one validated snapshot into an existing model of the registered
  /// type.
  public func apply(
    _ snapshot: CloudRecordSnapshot,
    to model: any PersistentModel
  ) throws {
    try applySnapshotImplementation(snapshot, model)
  }

  /// Materializes a new application model from one validated snapshot.
  public func materialize(
    _ snapshot: CloudRecordSnapshot
  ) throws -> any PersistentModel {
    try materializeImplementation(snapshot)
  }

  /// Returns the generated asset operation for a typed computed slot.
  public func asset<Model: PersistentModel>(
    matching keyPath: KeyPath<Model, CloudAssetSlot>
  ) -> CloudAssetRegistration? {
    assets.first { $0.matches(keyPath) }
  }
}

/// Misuse errors raised at the type-erased registration boundary.
public enum CloudModelRegistrationError: Error, Sendable, Equatable {
  /// An operation received a SwiftData model other than the registered type.
  case modelTypeMismatch(expected: String, actual: String)
}
