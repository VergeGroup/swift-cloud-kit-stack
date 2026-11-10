import CloudKitData
import CloudKitDataConsumerFixture
import Foundation
import SwiftData
import Testing

@Suite(.serialized)
struct CloudKitDataTests {
  @Test
  func schemaComesFromConsumerOwnedModels() throws {
    let schema = try CloudDataSchema(
      models: [Card.self, Attachment.self, StringIdentityModel.self]
    )

    #expect(schema.registrations.count == 2)
    #expect(schema.registration(forRecordType: "Card") != nil)
    #expect(schema.registration(forRecordType: "StringIdentity") != nil)
    #expect(schema.registration(forRecordType: "Attachment") == nil)
    #expect(schema.zoneDomain == "vault")
    #expect(
      Card.cloudModelRegistration.descriptor
        == CloudModelDescriptor(
          recordType: "Card",
          zoneDomain: "vault",
          recordNameKind: .uuid,
          fields: [
            .init(key: "kind", kind: .string, isOptional: false),
            .init(key: "body", kind: .string, isOptional: false),
            .init(key: "createdAt", kind: .date, isOptional: false),
            .init(key: "score", kind: .double, isOptional: true),
            .init(key: "isPinned", kind: .bool, isOptional: false),
            .init(key: "revision", kind: .int, isOptional: false),
            .init(key: "byteSize", kind: .int64, isOptional: false),
            .init(key: "payload", kind: .data, isOptional: true),
            .init(key: "location", kind: .location, isOptional: true),
          ],
          relationships: []
        )
    )
  }

  @Test
  func relationshipMetadataAndTypedOperationComeFromTheSourceModel() throws {
    let schema = try CloudDataSchema(
      models: [Card.self, CardEdge.self, Attachment.self]
    )
    let relationship = try #require(
      CardEdge.cloudModelRegistration.descriptor.relationships.first
    )
    #expect(
      relationship
        == CloudRelationshipDescriptor(
          key: "cardID",
          targetModelType: Card.self,
          localPropertyName: "card",
          storage: .recordName,
          requirement: .eventuallyRequired,
          isOptional: false
        )
    )
    #expect(schema.zoneDomain == "vault")

    let card = Card(kind: .text, body: "target", createdAt: .now)
    let edge = CardEdge(cardRecordName: card.id.uuidString)
    let operation = try #require(
      CardEdge.cloudModelRegistration.relationships.first
    )
    #expect(try operation.targetRecordName(from: edge) == card.id.uuidString)
    try operation.assignTarget(card, to: edge)
    #expect(edge.card === card)

    let snapshot = try CardEdge.cloudModelRegistration.makeSnapshot(from: edge)
    #expect(snapshot.fields["cardID"] == .string(card.id.uuidString))
    let materialized = try #require(
      try CardEdge.cloudModelRegistration.materialize(snapshot) as? CardEdge
    )
    #expect(materialized.cardRecordName == card.id.uuidString)
    #expect(materialized.card == nil)
  }

  @Test
  func assetMetadataAndTypedSlotsComeFromComputedProperties() throws {
    let schema = try CloudDataSchema(models: [AttachmentResource.self])
    let registration = AttachmentResource.cloudModelRegistration
    #expect(schema.zoneDomain == "vault")
    #expect(
      registration.descriptor.assets == [
        CloudAssetDescriptor(key: "file", propertyName: "fileAsset"),
        CloudAssetDescriptor(key: "thumbnail", propertyName: "thumbnailAsset"),
      ]
    )
    #expect(registration.assets.count == 2)

    let resource = AttachmentResource(mediaType: "image/jpeg")
    let fileOperation = try #require(
      registration.asset(matching: \AttachmentResource.fileAsset)
    )
    #expect(
      try fileOperation.slot(from: resource).localIdentifier
        == "\(resource.id.uuidString)/file"
    )
    let snapshot = try registration.makeSnapshot(from: resource)
    #expect(snapshot.fields == ["mediaType": .string("image/jpeg")])
  }

  @Test
  func wireFingerprintIncludesAssetKeys() throws {
    let twoAssets = try CloudDataSchema(models: [AttachmentResource.self])
    let oneAsset = try CloudDataSchema(
      models: [SingleAssetAttachmentResource.self]
    )

    #expect(twoAssets.wireSchemaFingerprint != oneAsset.wireSchemaFingerprint)
  }

  @Test
  func schemaRejectsMissingAndCrossDomainRelationshipTargets() {
    #expect(
      throws: CloudDataSchemaError.missingRelationshipTarget(
        sourceRecordType: "CardEdge",
        key: "cardID",
        targetModelType: String(reflecting: Card.self)
      )
    ) {
      try CloudDataSchema(models: [CardEdge.self])
    }

    #expect(
      throws: CloudDataSchemaError.relationshipZoneDomainMismatch(
        sourceRecordType: "CrossDomainEdge",
        key: "targetID",
        sourceZoneDomain: "vault",
        targetRecordType: "OtherDomain",
        targetZoneDomain: "other"
      )
    ) {
      try CloudDataSchema(
        models: [CrossDomainEdge.self, OtherDomainModel.self]
      )
    }

    #expect(
      throws: CloudDataSchemaError.mixedZoneDomains(["other", "vault"])
    ) {
      try CloudDataSchema(models: [Card.self, OtherDomainModel.self])
    }
  }

  @Test
  func generatedSnapshotRoundTripsAndMerges() throws {
    let id = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
    let payload = Data([0xCA, 0xFE])
    let location = Coordinate(latitude: 59.3293, longitude: 18.0686)
    let card = Card(
      id: id,
      kind: .text,
      body: "before",
      createdAt: createdAt,
      score: 0.75,
      isPinned: true,
      revision: 7,
      byteSize: 42,
      payload: payload,
      location: location
    )
    card.localDraft = "device-only"

    let registration = Card.cloudModelRegistration
    let encoded = try registration.makeSnapshot(from: card)
    #expect(encoded.recordName == id.uuidString)
    #expect(encoded.fields["kind"] == .string("text"))
    #expect(encoded.fields["body"] == .string("before"))
    #expect(encoded.fields["createdAt"] == .date(createdAt))
    #expect(encoded.fields["score"] == .double(0.75))
    #expect(encoded.fields["isPinned"] == .bool(true))
    #expect(encoded.fields["revision"] == .int(7))
    #expect(encoded.fields["byteSize"] == .int64(42))
    #expect(encoded.fields["payload"] == .data(payload))
    #expect(
      encoded.fields["location"]
        == .location(
          try #require(
            CloudLocationValue(
              latitude: location.latitude,
              longitude: location.longitude
            )
          )
        )
    )

    var fields = encoded.fields
    fields["body"] = .string("after")
    fields.removeValue(forKey: "score")
    try registration.apply(
      CloudRecordSnapshot(recordName: encoded.recordName, fields: fields),
      to: card
    )

    #expect(card.body == "after")
    #expect(card.score == nil)
    #expect(card.localDraft == "device-only")
  }

  @Test
  func generatedMaterializationPersistsInSwiftData() throws {
    let snapshot = CloudRecordSnapshot(
      recordName: UUID().uuidString,
      fields: [
        "kind": .string("todo"),
        "body": .string("persisted"),
        "createdAt": .date(Date(timeIntervalSince1970: 1_760_000_000)),
        "score": .double(0.5),
        "isPinned": .bool(true),
        "revision": .int(8),
        "byteSize": .int64(128),
        "payload": .data(Data([0x01])),
        "location": .location(
          try #require(
            CloudLocationValue(latitude: 35.6762, longitude: 139.6503)
          )
        ),
      ]
    )

    let persistentModel = try Card.cloudModelRegistration.materialize(snapshot)
    let card = try #require(persistentModel as? Card)
    #expect(card.kind == .todo)
    #expect(card.localDraft == "")
    #expect(card.transientCache == "cold")
    #expect(card.attachments.isEmpty)
    #expect(
      card.location == Coordinate(latitude: 35.6762, longitude: 139.6503)
    )

    let schema = try CloudDataSchema(models: [Card.self, Attachment.self])
    let configuration = ModelConfiguration(
      schema: schema.swiftDataSchema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: schema.swiftDataSchema,
      configurations: [configuration]
    )
    let context = ModelContext(container)
    context.insert(card)
    try context.save()

    let fetched = try #require(context.fetch(FetchDescriptor<Card>()).first)
    #expect(fetched.id.uuidString == snapshot.recordName)
    #expect(fetched.kind == .todo)
    #expect(fetched.body == "persisted")
    #expect(fetched.score == 0.5)
  }

  @Test
  func generatedSnapshotRejectsPartialAndInvalidLocations() throws {
    let card = Card(
      kind: .text,
      body: "location validation",
      createdAt: .now,
      location: nil
    )

    card.locationLatitude = 59.3293
    #expect(
      throws: CloudRecordSnapshotError.incompleteLocation(key: "location")
    ) {
      try Card.cloudModelRegistration.makeSnapshot(from: card)
    }

    card.locationLongitude = 18.0686
    card.locationLatitude = 91
    #expect(
      throws: CloudRecordSnapshotError.invalidLocation(key: "location")
    ) {
      try Card.cloudModelRegistration.makeSnapshot(from: card)
    }
  }

  @Test
  func reversedMacroOrderAndStringIdentityAreSupported() throws {
    let model = StringIdentityModel(recordName: "stable-name", value: "hello")
    let registration = StringIdentityModel.cloudModelRegistration
    let snapshot = try registration.makeSnapshot(from: model)

    #expect(snapshot.recordName == "stable-name")
    let materializedModel = try registration.materialize(snapshot)
    let materialized = try #require(materializedModel as? StringIdentityModel)
    #expect(materialized.value == "hello")
  }

  @Test
  func generatedRegistrationFetchesByStableRecordName() throws {
    let card = Card(kind: .text, body: "lookup", createdAt: .now)
    let schema = try CloudDataSchema(models: [Card.self, Attachment.self])
    let configuration = ModelConfiguration(
      schema: schema.swiftDataSchema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: schema.swiftDataSchema,
      configurations: [configuration]
    )
    let context = ModelContext(container)
    context.insert(card)
    try context.save()

    let fetched =
      try Card.cloudModelRegistration.fetch(
        recordName: card.id.uuidString,
        in: context
      ) as? Card
    #expect(fetched === card)
    #expect(
      try Card.cloudModelRegistration.fetch(
        recordName: UUID().uuidString,
        in: context
      ) == nil
    )
  }

  @Test
  func wireFingerprintIgnoresModelAndFieldDeclarationOrder() throws {
    let first = try CloudDataSchema(
      replayGeneration: 1,
      models: [Card.self, StringIdentityModel.self, Attachment.self]
    )
    let second = try CloudDataSchema(
      replayGeneration: 9,
      models: [Attachment.self, StringIdentityModel.self, Card.self]
    )

    #expect(first.wireSchemaFingerprint == second.wireSchemaFingerprint)
    #expect(first.replayGeneration != second.replayGeneration)
  }

  @Test
  func wireFingerprintIncludesRelationshipRequirementAndOptionality() throws {
    let required = try CloudDataSchema(
      models: [Card.self, RequiredFingerprintEdge.self]
    )
    let optional = try CloudDataSchema(
      models: [Card.self, OptionalFingerprintEdge.self]
    )

    #expect(required.wireSchemaFingerprint != optional.wireSchemaFingerprint)

    let optionalEdge = OptionalFingerprintEdge()
    let snapshot = try OptionalFingerprintEdge.cloudModelRegistration.makeSnapshot(
      from: optionalEdge
    )
    #expect(snapshot.fields["cardID"] == nil)
    let materialized = try #require(
      try OptionalFingerprintEdge.cloudModelRegistration.materialize(snapshot)
        as? OptionalFingerprintEdge
    )
    #expect(materialized.cardRecordName == nil)
    #expect(materialized.card == nil)
  }

  @Test
  func registrationRejectsWrongModelTypeAndIdentity() throws {
    let stringModel = StringIdentityModel(recordName: "name", value: "value")
    #expect(throws: CloudModelRegistrationError.self) {
      try Card.cloudModelRegistration.makeSnapshot(from: stringModel)
    }

    let card = Card(kind: .text, body: "body", createdAt: .now)
    let snapshot = try Card.cloudModelRegistration.makeSnapshot(from: card)
    #expect(throws: CloudRecordSnapshotError.self) {
      try Card.cloudModelRegistration.apply(
        CloudRecordSnapshot(recordName: "another", fields: snapshot.fields),
        to: card
      )
    }
  }

  @Test
  func schemaRejectsDuplicateModelAndRecordTypes() {
    #expect(
      throws: CloudDataSchemaError.duplicateModelType(
        String(reflecting: Card.self)
      )
    ) {
      try CloudDataSchema(models: [Card.self, Card.self])
    }

    #expect(throws: CloudDataSchemaError.duplicateRecordType("Card")) {
      try CloudDataSchema(models: [Card.self, DuplicateCardRecordTypeModel.self])
    }
  }
}
