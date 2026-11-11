import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(CloudKitDataMacros)
  import CloudKitDataMacros

  private let testMacros: [String: Macro.Type] = [
    "CloudAsset": CloudMarkerMacro.self,
    "CloudField": CloudMarkerMacro.self,
    "CloudLocation": CloudMarkerMacro.self,
    "CloudLocal": CloudMarkerMacro.self,
    "CloudRelationship": CloudMarkerMacro.self,
    "CloudRecordName": CloudMarkerMacro.self,
    "CloudSynced": CloudSyncedMacro.self,
  ]
#endif

final class CloudKitDataMacrosTests: XCTestCase {
  func testMinimalModelExpansion() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        @CloudSynced(recordType: "Note", zoneDomain: "vault")
        public final class Note {
          @CloudRecordName
          public var id: UUID

          @CloudField("title")
          public var title: String

          @CloudLocal
          public var isSelected: Bool = false
        }
        """,
        expandedSource: """
          public final class Note {
            public var id: UUID
            public var title: String
            public var isSelected: Bool = false

            /// The generated schema and field-mapping operations for this model.
            public static var cloudModelRegistration: CloudKitData.CloudModelRegistration {
              CloudKitData.CloudModelRegistration(
                modelType: Note.self,
                descriptor: CloudKitData.CloudModelDescriptor(
                  recordType: "Note",
                  zoneDomain: "vault",
                  recordNameKind: .uuid,
                  fields: [
                    CloudKitData.CloudFieldDescriptor(key: "title", kind: .string, isOptional: false)
                  ],
                  relationships: [],
                  assets: []
                ),
                relationships: [],
                assets: [],
                fetch: { recordName, context in
                  guard let _cloudIdentity = Foundation.UUID(uuidString: recordName) else {
                    throw CloudKitData.CloudRecordSnapshotError.invalidRecordName(recordName)
                  }
                  var descriptor = SwiftData.FetchDescriptor<Note>(
                    predicate: #Predicate<Note> { model in
                      model.id == _cloudIdentity
                    }
                  )
                  descriptor.fetchLimit = 1
                  return try context.fetch(descriptor).first
                },
                makeSnapshot: { model in
                  try model._cloudRecordSnapshot()
                },
                applySnapshot: { model, snapshot in
                  try model._applyCloudRecordSnapshot(snapshot)
                },
                materialize: { snapshot in
                  try Note(_cloudRecordSnapshot: snapshot)
                }
              )
            }

            private struct _CloudDecodedValues {
              let id: UUID
              let title: String
            }

            private static func _decodeCloudRecordSnapshot(
              _ snapshot: CloudKitData.CloudRecordSnapshot
            ) throws -> _CloudDecodedValues {
              guard let _cloudIdentity = Foundation.UUID(uuidString: snapshot.recordName) else {
                throw CloudKitData.CloudRecordSnapshotError.invalidRecordName(snapshot.recordName)
              }
              guard let _cloudValue0 = snapshot.fields["title"] else {
                throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
                  key: "title",
                  expected: .string
                )
              }
              guard case .string(let _cloudField0) = _cloudValue0 else {
                throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
                  key: "title",
                  expected: .string
                )
              }
              return _CloudDecodedValues(
                id: _cloudIdentity,
                title: _cloudField0
              )
            }

            private init(
              _cloudRecordSnapshot snapshot: CloudKitData.CloudRecordSnapshot
            ) throws {
              let values = try Self._decodeCloudRecordSnapshot(snapshot)
              self.id = values.id
              self.title = values.title
              self.isSelected = false
            }

            private func _cloudRecordSnapshot() throws -> CloudKitData.CloudRecordSnapshot {
              var fields: [String: CloudKitData.CloudFieldValue] = [:]
              fields["title"] = CloudKitData.CloudFieldValue.string(self.title)
              return CloudKitData.CloudRecordSnapshot(
                recordName: self.id.uuidString,
                fields: fields
              )
            }

            private func _applyCloudRecordSnapshot(
              _ snapshot: CloudKitData.CloudRecordSnapshot
            ) throws {
              let expectedRecordName = self.id.uuidString
              guard snapshot.recordName == expectedRecordName else {
                throw CloudKitData.CloudRecordSnapshotError.recordNameMismatch(
                  expected: expectedRecordName,
                  actual: snapshot.recordName
                )
              }
              let values = try Self._decodeCloudRecordSnapshot(snapshot)
              self.title = values.title
            }
          }

          extension Note: CloudKitData.CloudSyncedModel {
          }
          """,
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testRelationshipExpansion() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        @CloudSynced(recordType: "CardEdge", zoneDomain: "vault")
        final class CardEdge {
          @CloudRecordName
          var id: UUID

          @CloudRelationship(
            "cardID",
            target: Card.self,
            local: \\CardEdge.card,
            requirement: .eventuallyRequired
          )
          var cardRecordName: String

          @Relationship
          var card: Card?
        }
        """,
        expandedSource: """
          final class CardEdge {
            var id: UUID
            var cardRecordName: String

            @Relationship
            var card: Card?

            /// The generated schema and field-mapping operations for this model.
            static var cloudModelRegistration: CloudKitData.CloudModelRegistration {
              CloudKitData.CloudModelRegistration(
                modelType: CardEdge.self,
                descriptor: CloudKitData.CloudModelDescriptor(
                  recordType: "CardEdge",
                  zoneDomain: "vault",
                  recordNameKind: .uuid,
                  fields: [],
                  relationships: [
                    CloudKitData.CloudRelationshipDescriptor(
                      key: "cardID",
                      targetModelType: Card.self,
                      localPropertyName: "card",
                      storage: .recordName,
                      requirement: .eventuallyRequired,
                      isOptional: false
                    )
                  ],
                  assets: []
                ),
                relationships: [
                  CloudKitData.CloudRelationshipRegistration(
                    sourceModelType: CardEdge.self,
                    targetModelType: Card.self,
                    descriptor: CloudKitData.CloudRelationshipDescriptor(
                      key: "cardID",
                      targetModelType: Card.self,
                      localPropertyName: "card",
                      storage: .recordName,
                      requirement: .eventuallyRequired,
                      isOptional: false
                    ),
                    targetRecordName: { source in
                      source.cardRecordName
                    },
                    local: \\CardEdge.card
                  )
                ],
                assets: [],
                fetch: { recordName, context in
                  guard let _cloudIdentity = Foundation.UUID(uuidString: recordName) else {
                    throw CloudKitData.CloudRecordSnapshotError.invalidRecordName(recordName)
                  }
                  var descriptor = SwiftData.FetchDescriptor<CardEdge>(
                    predicate: #Predicate<CardEdge> { model in
                      model.id == _cloudIdentity
                    }
                  )
                  descriptor.fetchLimit = 1
                  return try context.fetch(descriptor).first
                },
                makeSnapshot: { model in
                  try model._cloudRecordSnapshot()
                },
                applySnapshot: { model, snapshot in
                  try model._applyCloudRecordSnapshot(snapshot)
                },
                materialize: { snapshot in
                  try CardEdge(_cloudRecordSnapshot: snapshot)
                }
              )
            }

            private struct _CloudDecodedValues {
              let id: UUID
              let cardRecordName: String
            }

            private static func _decodeCloudRecordSnapshot(
              _ snapshot: CloudKitData.CloudRecordSnapshot
            ) throws -> _CloudDecodedValues {
              guard let _cloudIdentity = Foundation.UUID(uuidString: snapshot.recordName) else {
                throw CloudKitData.CloudRecordSnapshotError.invalidRecordName(snapshot.recordName)
              }
              guard let _cloudValue0 = snapshot.fields["cardID"] else {
                throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
                  key: "cardID",
                  expected: .string
                )
              }
              guard case .string(let _cloudField0) = _cloudValue0 else {
                throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
                  key: "cardID",
                  expected: .string
                )
              }
              return _CloudDecodedValues(
                id: _cloudIdentity,
                cardRecordName: _cloudField0
              )
            }

            private init(
              _cloudRecordSnapshot snapshot: CloudKitData.CloudRecordSnapshot
            ) throws {
              let values = try Self._decodeCloudRecordSnapshot(snapshot)
              self.id = values.id
              self.cardRecordName = values.cardRecordName
              self.card = nil
            }

            private func _cloudRecordSnapshot() throws -> CloudKitData.CloudRecordSnapshot {
              var fields: [String: CloudKitData.CloudFieldValue] = [:]
              fields["cardID"] = CloudKitData.CloudFieldValue.string(self.cardRecordName)
              return CloudKitData.CloudRecordSnapshot(
                recordName: self.id.uuidString,
                fields: fields
              )
            }

            private func _applyCloudRecordSnapshot(
              _ snapshot: CloudKitData.CloudRecordSnapshot
            ) throws {
              let expectedRecordName = self.id.uuidString
              guard snapshot.recordName == expectedRecordName else {
                throw CloudKitData.CloudRecordSnapshotError.recordNameMismatch(
                  expected: expectedRecordName,
                  actual: snapshot.recordName
                )
              }
              let values = try Self._decodeCloudRecordSnapshot(snapshot)
              self.cardRecordName = values.cardRecordName
            }
          }

          extension CardEdge: CloudKitData.CloudSyncedModel {
          }
          """,
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testZoneDomainDiagnostics() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        let zoneDomain: StaticString = "vault"

        @CloudSynced(recordType: "DynamicZone", zoneDomain: zoneDomain)
        final class DynamicZone {
          @CloudRecordName
          var id: UUID
        }

        @CloudSynced(recordType: "EmptyZone", zoneDomain: "")
        final class EmptyZone {
          @CloudRecordName
          var id: UUID
        }
        """,
        expandedSource: """
          let zoneDomain: StaticString = "vault"
          final class DynamicZone {
            var id: UUID
          }
          final class EmptyZone {
            var id: UUID
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@CloudSynced zoneDomain must be a string literal",
            line: 3,
            column: 53
          ),
          DiagnosticSpec(
            message: "@CloudSynced zoneDomain cannot be empty",
            line: 9,
            column: 51
          ),
        ],
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testRelationshipDiagnostics() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        @CloudSynced(recordType: "BrokenEdge", zoneDomain: "vault")
        final class BrokenEdge {
          @CloudRecordName
          var id: UUID

          @CloudRelationship(
            "targetID",
            target: Target.self,
            local: \\BrokenEdge.target,
            requirement: .eventuallyRequired
          )
          var targetRecordName: String?

          @Relationship
          var target: Target?

          @CloudRelationship(
            "otherID",
            target: Target.self,
            local: \\OtherEdge.target,
            requirement: .optional
          )
          var otherRecordName: String?
        }
        """,
        expandedSource: """
          final class BrokenEdge {
            var id: UUID
            var targetRecordName: String?

            @Relationship
            var target: Target?
            var otherRecordName: String?
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@CloudRelationship requirement .eventuallyRequired does not match the raw String optionality",
            line: 12,
            column: 25
          ),
          DiagnosticSpec(
            message:
              "@CloudRelationship local must be a direct key path rooted at BrokenEdge",
            line: 20,
            column: 12
          ),
        ],
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testFocusedDiagnostics() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        let key: StaticString = "value"

        @CloudSynced(recordType: "Broken", zoneDomain: "vault")
        final class Broken {
          @CloudRecordName
          var id: UUID

          @CloudField(key)
          var custom: CustomValue

          @CloudField("duplicate")
          var first: String

          @CloudField("duplicate")
          var second: String

          var unclassified: String

          @CloudField("computed")
          var computed: String { "value" }
        }
        """,
        expandedSource: """
          let key: StaticString = "value"
          final class Broken {
            var id: UUID
            var custom: CustomValue
            var first: String
            var second: String

            var unclassified: String
            var computed: String { "value" }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@CloudField does not support stored type 'CustomValue'",
            line: 9,
            column: 15
          ),
          DiagnosticSpec(
            message: "duplicate Cloud wire key 'duplicate'",
            line: 14,
            column: 3
          ),
          DiagnosticSpec(
            message: "persisted property 'unclassified' must be explicitly classified",
            line: 17,
            column: 3
          ),
          DiagnosticSpec(
            message: "computed property 'computed' cannot be a Cloud field",
            line: 19,
            column: 3
          ),
        ],
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testLiteralAndCodecDiagnostics() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        let recordType: StaticString = "Note"

        @CloudSynced(recordType: recordType, zoneDomain: "vault")
        final class Note {
          @CloudRecordName
          var id: UUID

          @CloudField("title", codec: CustomCodec.self)
          var title: String
        }
        """,
        expandedSource: """
          let recordType: StaticString = "Note"
          final class Note {
            var id: UUID
            var title: String
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@CloudSynced recordType must be a string literal",
            line: 3,
            column: 26
          ),
          DiagnosticSpec(
            message: "@CloudField accepts exactly one unlabeled field-key literal and no codec",
            line: 8,
            column: 3
          ),
        ],
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testLocationDiagnostics() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        @CloudSynced(recordType: "BrokenLocation", zoneDomain: "vault")
        final class BrokenLocation {
          @CloudRecordName
          var id: UUID

          @CloudLocation("missing", component: .latitude)
          var missingLongitude: Double?

          @CloudLocation("mismatch", component: .latitude)
          var requiredLatitude: Double

          @CloudLocation("mismatch", component: .longitude)
          var optionalLongitude: Double?

          @CloudLocation("wrong", component: .latitude)
          var wrong: String

          @CloudLocation("computed", component: .longitude)
          var computed: Double? { nil }
        }
        """,
        expandedSource: """
          final class BrokenLocation {
            var id: UUID
            var missingLongitude: Double?
            var requiredLatitude: Double
            var optionalLongitude: Double?
            var wrong: String
            var computed: Double? { nil }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@CloudLocation must be attached to Double or Double?, not 'String'",
            line: 16,
            column: 14
          ),
          DiagnosticSpec(
            message: "@CloudLocation component 'computed' must be a stored property",
            line: 18,
            column: 3
          ),
          DiagnosticSpec(
            message: "Cloud location 'missing' is missing its .longitude component",
            line: 6,
            column: 3
          ),
          DiagnosticSpec(
            message: "Cloud location 'mismatch' components must have matching optionality",
            line: 12,
            column: 3
          ),
        ],
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testFieldKeyMustBeLiteral() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        let key: StaticString = "value"

        @CloudSynced(recordType: "Literal", zoneDomain: "vault")
        final class Literal {
          @CloudRecordName
          var id: UUID

          @CloudField(key)
          var value: String
        }
        """,
        expandedSource: """
          let key: StaticString = "value"
          final class Literal {
            var id: UUID
            var value: String
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@CloudField key must be a string literal",
            line: 8,
            column: 15
          )
        ],
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testAssetDiagnostics() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        let key: StaticString = "dynamic"

        @CloudSynced(recordType: "BrokenAsset", zoneDomain: "vault")
        final class BrokenAsset {
          @CloudRecordName
          var id: UUID

          @CloudAsset("stored")
          var stored: CloudAssetSlot = CloudAssetSlot(localIdentifier: "stored")

          @CloudAsset(key)
          var dynamic: CloudAssetSlot {
            CloudAssetSlot(localIdentifier: "dynamic")
          }

          @CloudAsset("wrong")
          var wrong: URL { URL(fileURLWithPath: "/tmp/wrong") }

          @CloudField("duplicate")
          var value: String

          @CloudAsset("duplicate")
          var duplicate: CloudAssetSlot {
            CloudAssetSlot(localIdentifier: "duplicate")
          }
        }
        """,
        expandedSource: """
          let key: StaticString = "dynamic"
          final class BrokenAsset {
            var id: UUID
            var stored: CloudAssetSlot = CloudAssetSlot(localIdentifier: "stored")
            var dynamic: CloudAssetSlot {
              CloudAssetSlot(localIdentifier: "dynamic")
            }
            var wrong: URL { URL(fileURLWithPath: "/tmp/wrong") }
            var value: String
            var duplicate: CloudAssetSlot {
              CloudAssetSlot(localIdentifier: "duplicate")
            }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@CloudAsset property 'stored' must be computed, not stored",
            line: 8,
            column: 3
          ),
          DiagnosticSpec(
            message: "@CloudAsset key must be a string literal",
            line: 11,
            column: 15
          ),
          DiagnosticSpec(
            message: "@CloudAsset computed property must have type CloudAssetSlot, not 'URL'",
            line: 17,
            column: 14
          ),
          DiagnosticSpec(
            message: "duplicate Cloud wire key 'duplicate'",
            line: 22,
            column: 3
          ),
        ],
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testAssetSlotMustBeReadOnly() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        @CloudSynced(recordType: "WritableAsset", zoneDomain: "vault")
        final class WritableAsset {
          @CloudRecordName
          var id: UUID

          @CloudAsset("file")
          var asset: CloudAssetSlot {
            get { CloudAssetSlot(localIdentifier: "file") }
            set {}
          }
        }
        """,
        expandedSource: """
          final class WritableAsset {
            var id: UUID
            var asset: CloudAssetSlot {
              get { CloudAssetSlot(localIdentifier: "file") }
              set {}
            }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@CloudAsset property 'asset' must be read-only",
            line: 6,
            column: 3
          )
        ],
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }

  func testIdentityAndLocalDefaultDiagnostics() throws {
    #if canImport(CloudKitDataMacros)
      assertMacroExpansion(
        """
        @CloudSynced(recordType: "Broken", zoneDomain: "vault")
        final class Broken {
          @CloudField("uuid")
          var id: UUID

          @CloudLocal
          var cache: String
        }
        """,
        expandedSource: """
          final class Broken {
            var id: UUID
            var cache: String
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@CloudField does not support stored type 'UUID'",
            line: 4,
            column: 11
          ),
          DiagnosticSpec(
            message:
              "local, relationship, or transient property 'cache' needs a source default for generated materialization",
            line: 7,
            column: 7
          ),
          DiagnosticSpec(
            message: "@CloudSynced requires exactly one @CloudRecordName property",
            line: 1,
            column: 1
          ),
        ],
        macros: testMacros,
        indentationWidth: .spaces(2)
      )
    #else
      throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }
}
