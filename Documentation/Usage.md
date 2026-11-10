# Model mapping and synchronization

`CloudKitData` is a Swift package for declaring an explicit
CloudKit wire schema on an application-owned SwiftData model.

The package does not own concrete application models. Types such as `Card` and
`Vault` remain in the consuming application's first-party module. The package
provides macros, immutable descriptors, transport-neutral field values,
and type-erased schema registration.

```swift
import CloudKitData
import Foundation
import SwiftData

@Model
@CloudSynced(recordType: "Card", zoneDomain: "vault")
public final class Card {
  @Attribute(.unique)
  @CloudRecordName
  public var id: UUID

  @CloudField("body")
  public var body: String

  public init(id: UUID = UUID(), body: String) {
    self.id = id
    self.body = body
  }
}

let schema = try CloudDataSchema(models: [Card.self])
```

Every synchronized field has an explicit literal key. Custom stored codecs are
intentionally unsupported: domain-specific values should be computed from raw
primitive properties.

Native CloudKit locations remain query-friendly SwiftData primitives. Each
component repeats the same explicit wire key so the macro can prove the pair
without a naming convention or custom codec:

```swift
@CloudLocation("location", component: .latitude)
public var locationLatitude: Double?

@CloudLocation("location", component: .longitude)
public var locationLongitude: Double?
```

`@CloudSynced` emits one optional `location` field. Outgoing mapping requires
both components or neither, validates geographic ranges, and
`CloudKitDataStack` alone converts the CK-free pair to and from `CLLocation`.
An application-specific `Coordinate` should remain an ordinary computed
property over these two stored columns.

To-one relationships keep an explicit record-name source property. The local
SwiftData relationship is optional so a source can materialize before an
out-of-order target arrives:

```swift
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
```

`zoneDomain` is a logical graph partition, not a CloudKit zone name. One
`CloudDataSchema` accepts one nonempty domain; each store separately binds that
schema to an exact database scope, zone name, and owner.

CKAsset-backed fields use an explicit, read-only computed slot. The model
persists only primitive metadata; neither `CKAsset` nor a file URL becomes a
SwiftData property:

```swift
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

  public init(id: UUID = UUID(), mediaType: String) {
    self.id = id
    self.mediaType = mediaType
  }
}
```

The literal is the stable CKRecord field key. `localIdentifier` is interpreted
only by consumer filesystem hooks and is never sent to CloudKit.

## Integrated stack

`CloudKitDataStack` is a separate product. It imports CloudKit internally, but
its public setup, routing, errors, and observation use library-owned values.

```swift
import CloudKitData
import CloudKitDataStack

let storeConfiguration = CloudDataStoreConfiguration(
  id: .init(rawValue: "primary"),
  location: .file(applicationSupportURL.appendingPathComponent("Content.store")),
  remoteZone: .init(
    databaseScope: .private,
    zoneID: .init(zoneName: "primary-zone")
  )
)

let stack = try CloudKitDataStack(
  schema: schema,
  stores: CloudDataStoreDirectory(
    knownStores: [storeConfiguration],
    engineStateDirectoryURL: applicationSupportURL.appendingPathComponent("SyncState")
  ),
  transport: .cloudKit(
    containerIdentifier: "iCloud.example.app",
    databaseScopes: [.private],
    subscriptionIDs: [
      .private: .init(rawValue: "example.sync.private.v1")
    ]
  ),
  assetStore: assetStore
)

await stack.start()
```

`subscriptionIDs` is optional for a new integration. A consumer migrating an
existing CloudKit sync implementation should supply its stable database
subscription ID for each enabled scope so CKSyncEngine reuses that identity
instead of creating another silent subscription. Empty IDs and IDs for disabled
scopes fail during stack setup.

Previews and networkless tests use the same setup with `transport: .offline`.
Local stores open during initialization; CloudKit availability is represented
separately by `stack.observation`.

An asset-enabled CloudKit schema requires CK-free filesystem hooks. The package
provides immutable staging destinations and package-owned incoming source URLs;
the consumer resolves application paths and applies retention policy:

```swift
let assetStore = CloudDataAssetStore(
  materializeOutgoing: { reference, packageDestinationURL in
    let sourceURL = try mediaStore.sourceURL(
      for: reference.localIdentifier
    )
    try FileManager.default.copyItem(
      at: sourceURL,
      to: packageDestinationURL
    )
  },
  installIncoming: { reference, action in
    switch action {
    case .replace(let packageFileURL):
      try mediaStore.install(
        from: packageFileURL,
        as: reference.localIdentifier
      )
    case .remove:
      try mediaStore.applyRemoteRemoval(
        for: reference.localIdentifier
      )
    }
  }
)
```

Both hooks must be idempotent. Incoming package files are read-only and must be
copied rather than moved. A fetched record tombstone durably schedules
`.remove` for every declared slot in the same save that deletes the local
model, unless a local pending mutation is explicitly recreating that record.

### Transport-neutral inspection

Consumers can inspect account availability, custom zones, and per-zone record
totals without importing CloudKit or advancing CKSyncEngine state:

```swift
let account = try await stack.currentAccountIdentifierLookup()
let zones = try await stack.remoteZones()
if let zone = zones.first {
  let counts = try await stack.remoteRecordCounts(in: zone)
}
```

Zone enumeration and record counts are isolated network probes. They do not
materialize domain stores; consumers still decide which remote zones belong to
their domain and how those zones appear in a local catalog.

### Account changes

CloudKit clears an engine's account-scoped state when the signed-in account
changes. The stack persists the account authorized to receive retained local
stores separately from disposable engine serialization. A newly-created engine
reporting that same account is re-established internally: its zones and durable
outbox are re-seeded without raising another product-policy transition.

An initial sign-in, sign-out, or different account still persists a fail-closed
`.accountChangeRequiresResolution` state, stops every engine, and keeps local
stores/outbox writes available. After the product has decided that retained
local data may be synchronized under the reported transition, explicitly
restart clean engines:

```swift
if case .accountChangeRequiresResolution =
  stack.observation.transportAvailability
{
  // Apply the product's keep/delete/migration policy first.
  try await stack.resumeTransportAfterAccountChange()
}
```

Do not call this automatically for an account switch. If local account-scoped
stores are replaced or deleted, construct a new stack after that policy work.
The account authorization is container-scoped and intentionally survives wire
schema and replay-generation changes; CKSyncEngine serialization does not.

Consumer lifecycle events raised by CKSyncEngine are delivered FIFO from a
detached task. Event handlers may call back into the stack, including
`resumeTransportAfterAccountChange()`, without running that engine operation in
CloudKit's delegate-callback context. These events are follow-up notifications;
synchronous merge and deletion decisions remain in the transaction-scoped
store-policy hooks. Store commits that change transport intent cross the same
detached boundary before reseeding or sending changes.

### Authored transactions

The stack does not intercept arbitrary `ModelContext.save()` calls. Every
synchronized authored write explicitly records its intent inside the same
SwiftData save:

```swift
let store = stack.store(for: .init(rawValue: "primary"))!

try store.transaction { transaction in
  card.body = "Updated"
  try transaction.synchronize(card)
}
```

Use `transaction.insert(model)` and `transaction.delete(model)` for the common
create/delete cases. The durable outbox stores only record identity and intent;
the current model is encoded immediately before a CKSyncEngine batch.

A transaction that mutates only `modelContext` remains local-only: it commits
SwiftData and refreshes observation metrics without waking CloudKit transport.
Calling `synchronize`, `insert`, `delete`, `tombstone`, or an asset-intent API
marks the transaction as transport-relevant. This distinction lets consumers
update local presentation state after a remote import without accidentally
calling back into CKSyncEngine from its delegate event.

Asset replacement has an asynchronous preparation step so large file copying
does not occur inside the main-context transaction:

```swift
let prepared = try await store.prepareAssetReplacement(
  for: resource,
  at: \AttachmentResource.fileAsset
)

try store.transaction { transaction in
  resource.localFileRevision += 1
  try transaction.replaceAsset(
    resource,
    at: \AttachmentResource.fileAsset,
    with: prepared
  )
}
```

Use `removeAsset(_:at:)` for an explicit remote clear and
`preserveAsset(_:at:)` for an explicit no-change intent. Preserve adds no new
asset field mutation; it does not cancel a replacement or removal that is
already durable for the record. A missing local file or an incremented local
revision never implies remote removal.

## Target boundaries

- Concrete SwiftData models stay in the consumer module.
- `CloudKitData` does not import CloudKit or expose `CKRecord` types.
- `CloudKitDataStack` owns stable ModelContainers, library system entities,
  transactional outbox, closed CKRecord field conversion, private/shared
  CKSyncEngine lifecycle/state, stable silent-subscription selection, durable
  account authorization and account-change gating, custom-zone
  routing/inspection, remote record-count probes, durable asset transfer/replay,
  and observable activity.
- Relationship descriptors, same-domain validation, and durable out-of-order
  to-one repair are package-owned. Placeholder, cycle, tree, and domain
  deletion policies remain consumer-owned.
- `CloudKitDataStack` exposes no CloudKit SDK type in its public declarations.
- Property-level asset descriptors, explicit preserve/replace/remove intents,
  immutable upload staging, incoming system-file capture, restart replay, and
  exact-revision cleanup are package-owned. Final filesystem placement,
  retention, shares, cross-process locking, and domain conflict/deletion policy
  remain consumer responsibilities.
- The initial generic scalar importer uses record-level local-pending-wins and
  a main-actor authored writer; these are reviewed again at app integration.

See [Integration](Integration.md) for platform support, installation, and
compatibility requirements.
