import CloudKitData
import CloudKitDataStack
import Foundation
import SwiftData

@Model
@CloudSynced(recordType: "Note", zoneDomain: "notes")
final class Note {

  @Attribute(.unique)
  @CloudRecordName
  var id: UUID

  @CloudField("text")
  var text: String

  init(id: UUID = UUID(), text: String) {
    self.id = id
    self.text = text
  }

}

@main
struct Notes {

  enum Failure: Error {
    case usage
    case nonemptySeedDirectory
    case missingStore
    case unexpectedContent
    case unexpectedOutbox
    case changedWireSchema
    case expectedRollback
  }

  @MainActor
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudKitData-Notes-\(UUID())")
      defer { try? FileManager.default.removeItem(at: root) }
      try seed(at: root)
      try verify(at: root)
      try await exerciseTransactions(at: root)
      print("Notes: insert, reopen, update, rollback, and tombstone passed.")
      return
    }

    guard arguments.count == 2 else {
      throw Failure.usage
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    switch arguments[0] {
    case "seed":
      try seed(at: root)
      print("Notes: saved content, outbox, and wire fingerprint.")
    case "verify":
      try verify(at: root)
      print("Notes: reopened content, outbox, and wire fingerprint match.")
    default:
      throw Failure.usage
    }
  }

  @MainActor
  static func makeStack(at root: URL) throws -> CloudKitDataStack {
    try CloudKitDataStack(
      schema: CloudDataSchema(models: [Note.self]),
      stores: CloudDataStoreDirectory(
        knownStores: [
          CloudDataStoreConfiguration(
            id: .init(rawValue: "notes"),
            location: .file(root.appendingPathComponent("Notes.store")),
            remoteZone: .init(
              databaseScope: .private,
              zoneID: .init(zoneName: "notes")
            )
          )
        ],
        engineStateDirectoryURL: root.appendingPathComponent("SyncState")
      ),
      transport: .offline
    )
  }

  @MainActor
  static func seed(at root: URL) throws {
    if FileManager.default.fileExists(atPath: root.path) {
      guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
        throw Failure.nonemptySeedDirectory
      }
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stack = try makeStack(at: root)
    guard let store = stack.store(for: .init(rawValue: "notes")) else {
      throw Failure.missingStore
    }
    try store.transaction { transaction in
      try transaction.insert(Note(text: "Hello CloudKitData"))
    }
    try stack.schema.wireSchemaFingerprint.write(
      to: root.appendingPathComponent("fingerprint.txt"),
      atomically: true,
      encoding: .utf8
    )
  }

  @MainActor
  static func verify(at root: URL) throws {
    let fingerprint = try String(
      contentsOf: root.appendingPathComponent("fingerprint.txt"),
      encoding: .utf8
    )
    let stack = try makeStack(at: root)
    guard let store = stack.store(for: .init(rawValue: "notes")) else {
      throw Failure.missingStore
    }
    guard stack.schema.wireSchemaFingerprint == fingerprint else {
      throw Failure.changedWireSchema
    }
    let notes = try ModelContext(store.modelContainer).fetch(FetchDescriptor<Note>())
    guard notes.count == 1, let note = notes.first, note.text == "Hello CloudKitData" else {
      throw Failure.unexpectedContent
    }
    let pending = try store.pendingMutations()
    guard pending.count == 1,
      let mutation = pending.first,
      mutation.recordName == note.id.uuidString,
      mutation.recordType == "Note",
      case .save = mutation.kind
    else {
      throw Failure.unexpectedOutbox
    }
  }

  @MainActor
  static func exerciseTransactions(at root: URL) async throws {
    let stack = try makeStack(at: root)
    await stack.start()
    guard let store = stack.store(for: .init(rawValue: "notes")) else {
      throw Failure.missingStore
    }
    let recordName = try store.transaction { transaction in
      guard let note = try transaction.modelContext.fetch(FetchDescriptor<Note>()).first else {
        throw Failure.unexpectedContent
      }
      note.text = "Updated"
      try transaction.synchronize(note)
      return note.id.uuidString
    }

    do {
      try store.transaction { transaction in
        guard let note = try transaction.modelContext.fetch(FetchDescriptor<Note>()).first else {
          throw Failure.unexpectedContent
        }
        note.text = "Must roll back"
        try transaction.synchronize(note)
        try transaction.insert(Note(text: "Must not persist"))
        throw Failure.expectedRollback
      }
    } catch Failure.expectedRollback {
    }

    let notes = try ModelContext(store.modelContainer).fetch(FetchDescriptor<Note>())
    guard notes.count == 1, notes.first?.text == "Updated" else {
      throw Failure.unexpectedContent
    }
    guard try store.pendingMutationCount() == 1 else {
      throw Failure.unexpectedOutbox
    }

    try store.transactionWithFreshContext { transaction in
      guard let note = try transaction.modelContext.fetch(FetchDescriptor<Note>()).first else {
        throw Failure.unexpectedContent
      }
      try transaction.delete(note)
      try transaction.tombstone(Note.self, recordName: recordName)
    }
    guard try ModelContext(store.modelContainer).fetchCount(FetchDescriptor<Note>()) == 0 else {
      throw Failure.unexpectedContent
    }
    let pending = try store.pendingMutations()
    guard pending.count == 1,
      let mutation = pending.first,
      mutation.recordName == recordName,
      case .delete = mutation.kind
    else {
      throw Failure.unexpectedOutbox
    }
  }

}
