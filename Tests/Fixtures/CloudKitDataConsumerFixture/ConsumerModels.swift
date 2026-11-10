import CloudKitData
import Foundation
import SwiftData

/// A domain value computed from synchronized primitive storage.
public struct Coordinate: Sendable, Equatable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// A local relationship model included in the same SwiftData model list.
@Model
public final class Attachment {
  public var name: String
  public var card: Card?

  public init(name: String, card: Card? = nil) {
    self.name = name
    self.card = card
  }
}

/// An application-owned model that exercises every supported field kind.
@Model
@CloudSynced(recordType: "Card", zoneDomain: "vault")
public final class Card {
  @Attribute(.unique)
  @CloudRecordName
  public private(set) var id: UUID

  @CloudField("kind")
  public private(set) var kindRawValue: String

  @CloudField("body")
  public var body: String

  @CloudField("createdAt")
  public var createdAt: Date

  @CloudField("score")
  public var score: Double?

  @CloudField("isPinned")
  public var isPinned: Bool

  @CloudField("revision")
  public var revision: Int

  @CloudField("byteSize")
  public var byteSize: Int64

  @CloudField("payload")
  public var payload: Data?

  @CloudLocation("location", component: .latitude)
  public var locationLatitude: Double?

  @CloudLocation("location", component: .longitude)
  public var locationLongitude: Double?

  @CloudLocal
  public var localDraft: String = ""

  @Transient
  public var transientCache: String = "cold"

  @Relationship(deleteRule: .cascade, inverse: \Attachment.card)
  public var attachments: [Attachment] = []

  public var kind: Kind {
    get { Kind(rawValue: kindRawValue) ?? .unknown }
    set { kindRawValue = newValue.rawValue }
  }

  public var location: Coordinate? {
    get {
      guard let locationLatitude, let locationLongitude else { return nil }
      return Coordinate(
        latitude: locationLatitude,
        longitude: locationLongitude
      )
    }
    set {
      locationLatitude = newValue?.latitude
      locationLongitude = newValue?.longitude
    }
  }

  public init(
    id: UUID = UUID(),
    kind: Kind,
    body: String,
    createdAt: Date,
    score: Double? = nil,
    isPinned: Bool = false,
    revision: Int = 0,
    byteSize: Int64 = 0,
    payload: Data? = nil,
    location: Coordinate? = nil
  ) {
    self.id = id
    self.kindRawValue = kind.rawValue
    self.body = body
    self.createdAt = createdAt
    self.score = score
    self.isPinned = isPinned
    self.revision = revision
    self.byteSize = byteSize
    self.payload = payload
    self.locationLatitude = location?.latitude
    self.locationLongitude = location?.longitude
  }

  public enum Kind: String, Sendable {
    case text
    case todo
    case unknown
  }
}

/// A reversed-annotation-order fixture with a String record identity.
@CloudSynced(recordType: "StringIdentity", zoneDomain: "vault")
@Model
public final class StringIdentityModel {
  @CloudRecordName
  public var recordName: String

  @CloudField("value")
  public var value: String

  public init(recordName: String, value: String) {
    self.recordName = recordName
    self.value = value
  }
}

/// A fixture used to verify duplicate record-type rejection.
@Model
@CloudSynced(recordType: "Card", zoneDomain: "vault")
public final class DuplicateCardRecordTypeModel {
  @CloudRecordName
  public var id: UUID

  @CloudField("value")
  public var value: String

  public init(id: UUID = UUID(), value: String) {
    self.id = id
    self.value = value
  }
}

/// A same-domain to-one relationship used for out-of-order repair fixtures.
@Model
@CloudSynced(recordType: "CardEdge", zoneDomain: "vault")
public final class CardEdge {
  @CloudRecordName
  public var id: UUID

  @CloudRelationship(
    "cardID",
    target: Card.self,
    local: \CardEdge.card,
    requirement: .eventuallyRequired
  )
  public var cardRecordName: String

  @Relationship
  public var card: Card?

  public init(
    id: UUID = UUID(),
    cardRecordName: String,
    card: Card? = nil
  ) {
    self.id = id
    self.cardRecordName = cardRecordName
    self.card = card
  }
}

/// A synchronized target intentionally placed in another logical graph.
@Model
@CloudSynced(recordType: "OtherDomain", zoneDomain: "other")
public final class OtherDomainModel {
  @CloudRecordName
  public var id: UUID

  @CloudField("value")
  public var value: String

  public init(id: UUID = UUID(), value: String) {
    self.id = id
    self.value = value
  }
}

/// A fixture whose relationship must be rejected during schema construction.
@Model
@CloudSynced(recordType: "CrossDomainEdge", zoneDomain: "vault")
public final class CrossDomainEdge {
  @CloudRecordName
  public var id: UUID

  @CloudRelationship(
    "targetID",
    target: OtherDomainModel.self,
    local: \CrossDomainEdge.target,
    requirement: .eventuallyRequired
  )
  public var targetRecordName: String

  @Relationship
  public var target: OtherDomainModel?

  public init(
    id: UUID = UUID(),
    targetRecordName: String,
    target: OtherDomainModel? = nil
  ) {
    self.id = id
    self.targetRecordName = targetRecordName
    self.target = target
  }
}

/// A required relationship fixture used to prove fingerprint sensitivity.
@Model
@CloudSynced(recordType: "FingerprintEdge", zoneDomain: "vault")
public final class RequiredFingerprintEdge {
  @CloudRecordName
  public var id: UUID

  @CloudRelationship(
    "cardID",
    target: Card.self,
    local: \RequiredFingerprintEdge.card,
    requirement: .eventuallyRequired
  )
  public var cardRecordName: String

  @Relationship
  public var card: Card?

  public init(id: UUID = UUID(), cardRecordName: String) {
    self.id = id
    self.cardRecordName = cardRecordName
  }
}

/// An optional variant with the same wire record type and relationship key.
@Model
@CloudSynced(recordType: "FingerprintEdge", zoneDomain: "vault")
public final class OptionalFingerprintEdge {
  @CloudRecordName
  public var id: UUID

  @CloudRelationship(
    "cardID",
    target: Card.self,
    local: \OptionalFingerprintEdge.card,
    requirement: .optional
  )
  public var cardRecordName: String?

  @Relationship
  public var card: Card?

  public init(id: UUID = UUID(), cardRecordName: String? = nil) {
    self.id = id
    self.cardRecordName = cardRecordName
  }
}

/// A synchronized resource with two CKAsset-backed computed slots.
///
/// Only primitive metadata is persisted in SwiftData. The slot identifiers are
/// interpreted later by the consumer-owned asset storage boundary.
@Model
@CloudSynced(recordType: "AttachmentResource", zoneDomain: "vault")
public final class AttachmentResource {
  @CloudRecordName
  public var id: UUID

  @CloudField("mediaType")
  public var mediaType: String

  @CloudLocal
  public var localFileRevision: Int = 0

  @CloudAsset("file")
  public var fileAsset: CloudAssetSlot {
    CloudAssetSlot(localIdentifier: "\(id.uuidString)/file")
  }

  @CloudAsset("thumbnail")
  public var thumbnailAsset: CloudAssetSlot {
    CloudAssetSlot(localIdentifier: "\(id.uuidString)/thumbnail")
  }

  public init(
    id: UUID = UUID(),
    mediaType: String,
    localFileRevision: Int = 0
  ) {
    self.id = id
    self.mediaType = mediaType
    self.localFileRevision = localFileRevision
  }
}

/// A one-slot variant used to prove that asset fields affect compatibility.
@Model
@CloudSynced(recordType: "AttachmentResource", zoneDomain: "vault")
public final class SingleAssetAttachmentResource {
  @CloudRecordName
  public var id: UUID

  @CloudField("mediaType")
  public var mediaType: String

  @CloudAsset("file")
  public var fileAsset: CloudAssetSlot {
    CloudAssetSlot(localIdentifier: "\(id.uuidString)/file")
  }

  public init(id: UUID = UUID(), mediaType: String) {
    self.id = id
    self.mediaType = mediaType
  }
}
