import CloudKitDataConsumerFixture
import CloudKitDataStack
import CloudKitDataStackConsumerFixture
import Foundation
import SwiftData
import Testing

@Suite(.serialized)
@MainActor
struct PublicTransactionTests {

  private enum Failure: Error {
    case abort
  }

  @Test
  func throwingTransactionRollsBackContentAndOutbox() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudKitData-Rollback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    do {
      let stack = try makeStack(at: root)
      let store = try #require(stack.store(for: .init(rawValue: "consumer")))
      try store.transaction { transaction in
        try transaction.insert(StringIdentityModel(recordName: "existing", value: "original"))
      }

      #expect(throws: Failure.self) {
        try store.transaction { transaction in
          let model = try #require(
            try transaction.modelContext.fetch(FetchDescriptor<StringIdentityModel>()).first
          )
          model.value = "attempted"
          try transaction.synchronize(model)
          try transaction.insert(StringIdentityModel(recordName: "new", value: "attempted"))
          throw Failure.abort
        }
      }

      let models = try ModelContext(store.modelContainer).fetch(FetchDescriptor<StringIdentityModel>())
      #expect(models.count == 1)
      #expect(models.first?.value == "original")
      #expect(try store.pendingMutations().map(\.recordName) == ["existing"])
    }

    let reopened = try makeStack(at: root)
    let store = try #require(reopened.store(for: .init(rawValue: "consumer")))
    let models = try ModelContext(store.modelContainer).fetch(FetchDescriptor<StringIdentityModel>())
    #expect(models.count == 1)
    #expect(models.first?.value == "original")
    #expect(try store.pendingMutations().map(\.recordName) == ["existing"])
  }

  @Test
  func explicitTombstoneRetainsCrossDeviceDeletionIntent() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudKitData-Tombstone-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stack = try makeStack(at: root)
    let store = try #require(stack.store(for: .init(rawValue: "consumer")))

    try store.transaction { transaction in
      try transaction.insert(StringIdentityModel(recordName: "shared-id", value: "local"))
    }
    try store.transactionWithFreshContext { transaction in
      let model = try #require(
        try transaction.modelContext.fetch(FetchDescriptor<StringIdentityModel>()).first
      )
      try transaction.delete(model)
    }
    #expect(try store.pendingMutationCount() == 0)

    try store.transaction { transaction in
      try transaction.tombstone(StringIdentityModel.self, recordName: "shared-id")
    }
    #expect(try ModelContext(store.modelContainer).fetchCount(FetchDescriptor<StringIdentityModel>()) == 0)
    let pending = try store.pendingMutations()
    #expect(pending.count == 1)
    let mutation = try #require(pending.first)
    #expect(mutation.recordName == "shared-id")
    #expect(mutation.kind == .delete)
  }

  private func makeStack(at root: URL) throws -> CloudKitDataStack {
    try makeConsumerOfflineStack(storeURL: root.appendingPathComponent("Content.store"))
  }

}
