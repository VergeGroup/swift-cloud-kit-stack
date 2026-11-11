import CloudKit
import Foundation

struct CloudDataEngineStateEnvelope: Codable, Sendable {
  static let currentFormatVersion = 2

  let formatVersion: Int
  let containerIdentifier: String
  let wireSchemaFingerprint: String
  let replayGeneration: Int
  let stateSerialization: CKSyncEngine.State.Serialization

  init(
    containerIdentifier: String,
    wireSchemaFingerprint: String,
    replayGeneration: Int,
    stateSerialization: CKSyncEngine.State.Serialization
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.containerIdentifier = containerIdentifier
    self.wireSchemaFingerprint = wireSchemaFingerprint
    self.replayGeneration = replayGeneration
    self.stateSerialization = stateSerialization
  }

  func isCompatible(
    containerIdentifier: String,
    wireSchemaFingerprint: String,
    replayGeneration: Int
  ) -> Bool {
    formatVersion == Self.currentFormatVersion
      && self.containerIdentifier == containerIdentifier
      && self.wireSchemaFingerprint == wireSchemaFingerprint
      && self.replayGeneration == replayGeneration
  }
}

private struct CloudDataPendingAccountChangeEnvelope: Codable, Sendable {
  static let currentFormatVersion = 1

  let formatVersion: Int
  let containerIdentifier: String
  let change: CloudDataAccountChange

  init(containerIdentifier: String, change: CloudDataAccountChange) {
    self.formatVersion = Self.currentFormatVersion
    self.containerIdentifier = containerIdentifier
    self.change = change
  }

  func isCompatible(containerIdentifier: String) -> Bool {
    formatVersion == Self.currentFormatVersion
      && self.containerIdentifier == containerIdentifier
  }
}

private struct CloudDataAuthorizedAccountEnvelope: Codable, Sendable {
  static let currentFormatVersion = 1

  let formatVersion: Int
  let containerIdentifier: String
  let accountIdentifier: CloudDataAccountIdentifier

  init(
    containerIdentifier: String,
    accountIdentifier: CloudDataAccountIdentifier
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.containerIdentifier = containerIdentifier
    self.accountIdentifier = accountIdentifier
  }

  func isCompatible(containerIdentifier: String) -> Bool {
    formatVersion == Self.currentFormatVersion
      && self.containerIdentifier == containerIdentifier
  }
}

enum CloudDataEngineStateStoreError: Error, Sendable, Equatable {
  case invalidPendingAccountChange
  case invalidAuthorizedAccount
}

/// Persists each database engine's token behind schema compatibility values.
struct CloudDataEngineStateStore: Sendable {
  let directoryURL: URL
  let containerIdentifier: String
  let wireSchemaFingerprint: String
  let replayGeneration: Int

  func prepareDirectory() throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
  }

  func load(
    scope: CloudDataDatabaseScope
  ) -> CKSyncEngine.State.Serialization? {
    guard
      let data = try? Data(contentsOf: fileURL(for: scope)),
      let envelope = try? JSONDecoder().decode(
        CloudDataEngineStateEnvelope.self,
        from: data
      ),
      envelope.isCompatible(
        containerIdentifier: containerIdentifier,
        wireSchemaFingerprint: wireSchemaFingerprint,
        replayGeneration: replayGeneration
      )
    else {
      return nil
    }
    return envelope.stateSerialization
  }

  func save(
    _ serialization: CKSyncEngine.State.Serialization,
    scope: CloudDataDatabaseScope
  ) throws {
    try prepareDirectory()
    let envelope = CloudDataEngineStateEnvelope(
      containerIdentifier: containerIdentifier,
      wireSchemaFingerprint: wireSchemaFingerprint,
      replayGeneration: replayGeneration,
      stateSerialization: serialization
    )
    let data = try JSONEncoder().encode(envelope)
    try data.write(to: fileURL(for: scope), options: .atomic)
  }

  /// Persists a fail-closed account transition independently of engine state.
  func savePendingAccountChange(_ change: CloudDataAccountChange) throws {
    try prepareDirectory()
    let envelope = CloudDataPendingAccountChangeEnvelope(
      containerIdentifier: containerIdentifier,
      change: change
    )
    try JSONEncoder().encode(envelope).write(
      to: pendingAccountChangeFileURL,
      options: .atomic
    )
  }

  /// Persists the account authorized to receive retained local stores.
  ///
  /// Unlike CKSyncEngine serialization, this binding survives schema and
  /// replay invalidation because it represents application data ownership,
  /// not a transport cursor.
  func saveAuthorizedAccount(_ account: CloudDataAccountIdentifier) throws {
    try prepareDirectory()
    let envelope = CloudDataAuthorizedAccountEnvelope(
      containerIdentifier: containerIdentifier,
      accountIdentifier: account
    )
    try JSONEncoder().encode(envelope).write(
      to: authorizedAccountFileURL,
      options: .atomic
    )
  }

  /// Returns the account currently authorized for retained local data.
  func loadAuthorizedAccount() throws -> CloudDataAccountIdentifier? {
    guard FileManager.default.fileExists(atPath: authorizedAccountFileURL.path) else {
      return nil
    }
    guard
      let data = try? Data(contentsOf: authorizedAccountFileURL),
      let envelope = try? JSONDecoder().decode(
        CloudDataAuthorizedAccountEnvelope.self,
        from: data
      ),
      envelope.isCompatible(containerIdentifier: containerIdentifier)
    else {
      throw CloudDataEngineStateStoreError.invalidAuthorizedAccount
    }
    return envelope.accountIdentifier
  }

  /// Returns a still-relevant account transition after process restart.
  func loadPendingAccountChange() throws -> CloudDataAccountChange? {
    guard FileManager.default.fileExists(atPath: pendingAccountChangeFileURL.path) else {
      return nil
    }
    guard
      let data = try? Data(contentsOf: pendingAccountChangeFileURL),
      let envelope = try? JSONDecoder().decode(
        CloudDataPendingAccountChangeEnvelope.self,
        from: data
      ),
      envelope.isCompatible(containerIdentifier: containerIdentifier)
    else {
      throw CloudDataEngineStateStoreError.invalidPendingAccountChange
    }
    return envelope.change
  }

  /// Removes all account-scoped engine tokens before an approved restart.
  func removeAllEngineStates() throws {
    for scope in CloudDataDatabaseScope.allCases {
      let url = fileURL(for: scope)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  /// Clears the durable account-policy gate after the consumer resolves it.
  func clearPendingAccountChange() throws {
    if FileManager.default.fileExists(atPath: pendingAccountChangeFileURL.path) {
      try FileManager.default.removeItem(at: pendingAccountChangeFileURL)
    }
  }

  private func fileURL(for scope: CloudDataDatabaseScope) -> URL {
    directoryURL.appendingPathComponent("cksyncengine-\(scope.rawValue).json")
  }

  private var pendingAccountChangeFileURL: URL {
    directoryURL.appendingPathComponent("pending-account-change.json")
  }

  private var authorizedAccountFileURL: URL {
    directoryURL.appendingPathComponent("authorized-account.json")
  }
}
