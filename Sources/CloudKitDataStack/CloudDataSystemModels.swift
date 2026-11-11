import Foundation
import SwiftData

/// A library-owned durable outbox row stored beside application models.
@Model
final class CloudDataPendingMutation {
  /// CloudKit record names are unique within a zone, independently of type.
  @Attribute(.unique)
  var recordName: String

  var recordType: String
  var kindRawValue: String
  var revisionRawValue: String?
  var enqueuedAt: Date
  var stagedAt: Date?
  var stagedRevisionRawValue: String?
  var latestErrorCategoryRawValue: String?
  var latestErrorMessage: String?
  var latestErrorAt: Date?

  init(
    recordName: String,
    recordType: String,
    kind: CloudDataMutationKind,
    revision: String = UUID().uuidString,
    enqueuedAt: Date = .now,
    stagedAt: Date? = nil
  ) {
    self.recordName = recordName
    self.recordType = recordType
    self.kindRawValue = kind.rawValue
    self.revisionRawValue = revision
    self.enqueuedAt = enqueuedAt
    self.stagedAt = stagedAt
  }

  var kind: CloudDataMutationKind? {
    get { CloudDataMutationKind(rawValue: kindRawValue) }
    set { kindRawValue = newValue?.rawValue ?? kindRawValue }
  }
}

/// One explicit outgoing asset intent coalesced by record and field key.
@Model
final class CloudDataPendingAssetMutation {
  @Attribute(.unique)
  var identity: String

  var recordType: String
  var recordName: String
  var fieldKey: String
  var localIdentifier: String
  var kindRawValue: String
  var mutationRevision: String
  var stagedFileID: String?
  var enqueuedAt: Date

  init(
    recordType: String,
    recordName: String,
    fieldKey: String,
    localIdentifier: String,
    kind: CloudDataAssetMutationKind,
    mutationRevision: String,
    stagedFileID: String?,
    enqueuedAt: Date = .now
  ) {
    self.identity = Self.makeIdentity(recordName: recordName, fieldKey: fieldKey)
    self.recordType = recordType
    self.recordName = recordName
    self.fieldKey = fieldKey
    self.localIdentifier = localIdentifier
    self.kindRawValue = kind.rawValue
    self.mutationRevision = mutationRevision
    self.stagedFileID = stagedFileID
    self.enqueuedAt = enqueuedAt
  }

  var kind: CloudDataAssetMutationKind? {
    get { CloudDataAssetMutationKind(rawValue: kindRawValue) }
    set { kindRawValue = newValue?.rawValue ?? kindRawValue }
  }

  static func makeIdentity(recordName: String, fieldKey: String) -> String {
    [recordName, fieldKey]
      .map { "\($0.utf8.count):\($0)" }
      .joined()
  }
}

/// One incoming asset value waiting for consumer-owned final installation.
@Model
final class CloudDataPendingAssetInstall {
  @Attribute(.unique)
  var identity: String

  var recordType: String
  var recordName: String
  var fieldKey: String
  var localIdentifier: String
  var kindRawValue: String
  var installRevision: String
  var stagedFileID: String?
  var observedAt: Date
  var latestErrorMessage: String?
  var latestErrorAt: Date?

  init(
    recordType: String,
    recordName: String,
    fieldKey: String,
    localIdentifier: String,
    kind: CloudDataAssetMutationKind,
    installRevision: String = UUID().uuidString,
    stagedFileID: String?,
    observedAt: Date = .now
  ) {
    self.identity = CloudDataPendingAssetMutation.makeIdentity(
      recordName: recordName,
      fieldKey: fieldKey
    )
    self.recordType = recordType
    self.recordName = recordName
    self.fieldKey = fieldKey
    self.localIdentifier = localIdentifier
    self.kindRawValue = kind.rawValue
    self.installRevision = installRevision
    self.stagedFileID = stagedFileID
    self.observedAt = observedAt
  }

  var kind: CloudDataAssetMutationKind? {
    get { CloudDataAssetMutationKind(rawValue: kindRawValue) }
    set { kindRawValue = newValue?.rawValue ?? kindRawValue }
  }
}

/// Durable ownership metadata for one package staging file.
@Model
final class CloudDataStagedAssetFile {
  @Attribute(.unique)
  var id: String

  var directionRawValue: String
  var recordName: String
  var fieldKey: String
  var createdAt: Date

  init(
    id: String,
    direction: CloudDataAssetTransferDirection,
    recordName: String,
    fieldKey: String,
    createdAt: Date = .now
  ) {
    self.id = id
    self.directionRawValue = direction.rawValue
    self.recordName = recordName
    self.fieldKey = fieldKey
    self.createdAt = createdAt
  }

  var direction: CloudDataAssetTransferDirection? {
    get { CloudDataAssetTransferDirection(rawValue: directionRawValue) }
    set { directionRawValue = newValue?.rawValue ?? directionRawValue }
  }
}

/// Archived CloudKit system fields for one last-accepted server record.
@Model
final class CloudDataSyncMetadata {
  @Attribute(.unique)
  var recordName: String

  var recordType: String
  var systemFieldsData: Data
  var acceptedAt: Date

  init(
    recordName: String,
    recordType: String,
    systemFieldsData: Data,
    acceptedAt: Date = .now
  ) {
    self.recordName = recordName
    self.recordType = recordType
    self.systemFieldsData = systemFieldsData
    self.acceptedAt = acceptedAt
  }
}

/// A durable out-of-order to-one relationship waiting for its target model.
@Model
final class CloudDataUnresolvedRelationship {
  /// Stable source/key identity used for idempotent upserts.
  @Attribute(.unique)
  var identity: String

  var sourceRecordType: String
  var sourceRecordName: String
  var relationshipKey: String
  var targetRecordType: String
  var targetRecordName: String
  var firstObservedAt: Date
  var lastAttemptedAt: Date

  init(
    sourceRecordType: String,
    sourceRecordName: String,
    relationshipKey: String,
    targetRecordType: String,
    targetRecordName: String,
    observedAt: Date = .now
  ) {
    self.identity = Self.makeIdentity(
      sourceRecordType: sourceRecordType,
      sourceRecordName: sourceRecordName,
      relationshipKey: relationshipKey
    )
    self.sourceRecordType = sourceRecordType
    self.sourceRecordName = sourceRecordName
    self.relationshipKey = relationshipKey
    self.targetRecordType = targetRecordType
    self.targetRecordName = targetRecordName
    self.firstObservedAt = observedAt
    self.lastAttemptedAt = observedAt
  }

  /// Builds an unambiguous identity without reserving a character that record
  /// names or wire keys would be forbidden to contain.
  static func makeIdentity(
    sourceRecordType: String,
    sourceRecordName: String,
    relationshipKey: String
  ) -> String {
    [sourceRecordType, sourceRecordName, relationshipKey]
      .map { "\($0.utf8.count):\($0)" }
      .joined()
  }
}

/// Remote operation represented by one durable pending mutation.
public enum CloudDataMutationKind: String, Sendable, Hashable, Codable {
  case save
  case delete
}

enum CloudDataAssetMutationKind: String, Sendable, Hashable {
  case replace
  case remove
}

enum CloudDataAssetTransferDirection: String, Sendable, Hashable {
  case outgoing
  case incoming
}

struct CloudDataStoreMetrics: Sendable, Hashable {
  let pendingCount: Int
  let stagedCount: Int
  let pendingAssetTransferCount: Int
}

enum CloudDataSystemSchema {
  static let modelTypes: [any PersistentModel.Type] = [
    CloudDataPendingMutation.self,
    CloudDataPendingAssetMutation.self,
    CloudDataPendingAssetInstall.self,
    CloudDataStagedAssetFile.self,
    CloudDataSyncMetadata.self,
    CloudDataUnresolvedRelationship.self,
  ]
}
