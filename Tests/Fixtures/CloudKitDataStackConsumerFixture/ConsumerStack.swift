import CloudKitData
import CloudKitDataConsumerFixture
import CloudKitDataStack
import Foundation

/// Compiles the public offline setup from a consumer that never imports CloudKit.
@MainActor
public func makeConsumerOfflineStack(
  storeURL: URL
) throws -> CloudKitDataStack {
  try makeConsumerStack(storeURL: storeURL, transport: .offline)
}

/// Compiles public CloudKit setup without importing the CloudKit SDK.
@MainActor
public func makeConsumerCloudStack(
  storeURL: URL,
  containerIdentifier: String
) throws -> CloudKitDataStack {
  try makeConsumerStack(
    storeURL: storeURL,
    transport: .cloudKit(
      containerIdentifier: containerIdentifier,
      databaseScopes: [.private, .shared],
      subscriptionIDs: [
        .private: .init(rawValue: "consumer.sync.private.v1"),
        .shared: .init(rawValue: "consumer.sync.shared.v1"),
      ]
    )
  )
}

/// Compiles an asset-enabled CloudKit setup without importing the CloudKit SDK.
@MainActor
public func makeConsumerCloudAssetStack(
  storeURL: URL,
  containerIdentifier: String,
  assetStore: CloudDataAssetStore
) throws -> CloudKitDataStack {
  let schema = try CloudDataSchema(models: [AttachmentResource.self])
  let store = CloudDataStoreConfiguration(
    id: .init(rawValue: "consumer-assets"),
    location: .file(storeURL),
    remoteZone: .init(
      databaseScope: .private,
      zoneID: .init(zoneName: "consumer-asset-zone")
    )
  )
  return try CloudKitDataStack(
    schema: schema,
    stores: CloudDataStoreDirectory(
      knownStores: [store],
      engineStateDirectoryURL:
        storeURL
        .deletingLastPathComponent()
        .appendingPathComponent("SyncState")
    ),
    transport: .cloudKit(
      containerIdentifier: containerIdentifier,
      databaseScopes: [.private]
    ),
    assetStore: assetStore
  )
}

/// Compiles transport-neutral CloudKit inspection without importing CloudKit.
@MainActor
public func inspectConsumerCloudStack(
  _ stack: CloudKitDataStack,
  remoteZone: CloudDataRemoteZone
) async throws -> (
  account: CloudDataAccountIdentifierLookup,
  zones: [CloudDataRemoteZone],
  counts: CloudDataRemoteRecordCounts
) {
  let account = try await stack.currentAccountIdentifierLookup()
  let zones = try await stack.remoteZones()
  let counts = try await stack.remoteRecordCounts(in: remoteZone)
  return (account, zones, counts)
}

@MainActor
private func makeConsumerStack(
  storeURL: URL,
  transport: CloudDataTransportConfiguration
) throws -> CloudKitDataStack {
  let schema = try CloudDataSchema(
    models: [Card.self, Attachment.self, StringIdentityModel.self]
  )
  let store = CloudDataStoreConfiguration(
    id: .init(rawValue: "consumer"),
    location: .file(storeURL),
    remoteZone: .init(
      databaseScope: .private,
      zoneID: .init(zoneName: "consumer-zone")
    )
  )
  return try CloudKitDataStack(
    schema: schema,
    stores: CloudDataStoreDirectory(
      knownStores: [store],
      engineStateDirectoryURL:
        storeURL
        .deletingLastPathComponent()
        .appendingPathComponent("SyncState")
    ),
    transport: transport
  )
}
