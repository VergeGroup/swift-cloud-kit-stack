import SwiftData

/// A type-erased generated operation for resolving one local to-one
/// relationship.
///
/// Immutable relationship metadata stays in `CloudRelationshipDescriptor`.
/// These closures are intentionally non-Sendable because SwiftData model
/// instances must remain on their owning context or actor.
public struct CloudRelationshipRegistration {
  /// The concrete application-owned source model type.
  public let sourceModelType: any PersistentModel.Type

  /// The concrete application-owned target model type.
  public let targetModelType: any PersistentModel.Type

  /// The immutable wire and resolution contract.
  public let descriptor: CloudRelationshipDescriptor

  private let targetRecordNameImplementation: (any PersistentModel) throws -> String?
  private let assignTargetImplementation:
    (any PersistentModel, (any PersistentModel)?) throws -> Void

  /// Captures the typed raw-identity reader and writable local relationship.
  ///
  /// Applications normally receive this operation from `@CloudRelationship`
  /// instead of constructing it manually.
  public init<Source: PersistentModel, Target: PersistentModel>(
    sourceModelType: Source.Type,
    targetModelType: Target.Type,
    descriptor: CloudRelationshipDescriptor,
    targetRecordName: @escaping (Source) -> String?,
    local: ReferenceWritableKeyPath<Source, Target?>
  ) {
    self.sourceModelType = sourceModelType
    self.targetModelType = targetModelType
    self.descriptor = descriptor

    let expectedSourceType = String(reflecting: sourceModelType)
    let expectedTargetType = String(reflecting: targetModelType)
    self.targetRecordNameImplementation = { source in
      guard let source = source as? Source else {
        throw CloudRelationshipRegistrationError.sourceModelTypeMismatch(
          expected: expectedSourceType,
          actual: String(reflecting: Swift.type(of: source))
        )
      }
      return targetRecordName(source)
    }
    self.assignTargetImplementation = { source, target in
      guard let source = source as? Source else {
        throw CloudRelationshipRegistrationError.sourceModelTypeMismatch(
          expected: expectedSourceType,
          actual: String(reflecting: Swift.type(of: source))
        )
      }
      guard let target else {
        source[keyPath: local] = nil
        return
      }
      guard let target = target as? Target else {
        throw CloudRelationshipRegistrationError.targetModelTypeMismatch(
          expected: expectedTargetType,
          actual: String(reflecting: Swift.type(of: target))
        )
      }
      source[keyPath: local] = target
    }
  }

  /// Reads the current raw target record name from a source instance.
  public func targetRecordName(
    from source: any PersistentModel
  ) throws -> String? {
    try targetRecordNameImplementation(source)
  }

  /// Assigns a resolved target, or clears the optional local relationship.
  public func assignTarget(
    _ target: (any PersistentModel)?,
    to source: any PersistentModel
  ) throws {
    try assignTargetImplementation(source, target)
  }
}

/// Misuse errors raised at a generated relationship operation boundary.
public enum CloudRelationshipRegistrationError: Error, Sendable, Equatable {
  /// A resolver received another source model type.
  case sourceModelTypeMismatch(expected: String, actual: String)

  /// A resolver received another target model type.
  case targetModelTypeMismatch(expected: String, actual: String)
}
