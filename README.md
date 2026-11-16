# CloudKitData

Explicit CloudKit synchronization for your own SwiftData models. Save locally
and queue the corresponding CloudKit changes in one transaction; local storage
remains available when CloudKit is offline.

`CloudKitData` provides model macros and schema mapping. `CloudKitDataStack`
opens the local stores and handles private/shared CloudKit synchronization.

## Getting started

This walkthrough creates a persistent Notes store with CloudKit disabled first,
so you can try initialization and local reads/writes without signing or an
iCloud account. Then [enable CloudKit](#enable-cloudkit) using the same store.

### 1. Add the package

In Xcode, add `https://github.com/VergeGroup/swift-cloud-kit-stack` under
**Package Dependencies** and link both products to your app target:

- `CloudKitData` — model declarations and schema.
- `CloudKitDataStack` — local persistence and CloudKit transport.

For separate model and app modules, link `CloudKitData` to the model module and
`CloudKitDataStack` to the app's composition root. See
[Integration](Documentation/Integration.md#package-dependency) for SwiftPM
manifest entries and revision pinning during the pre-1.0 period.

Requires iOS 17+ or macOS 14+. The package uses Swift 6 language mode and
SwiftSyntax 602.x; see [Integration](Documentation/Integration.md#package-dependency)
for toolchain details. Building requires Xcode on macOS.

### 2. Define a model

Keep your model in your app or model module. Add `@CloudSynced` alongside
SwiftData's `@Model`, choose a stable record identity, and give each synced
property an explicit CloudKit field key.

```swift
import CloudKitData
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
```

`id` becomes the CloudKit record name; do not change it after insertion. Record
names must be unique across model types in the same zone. `"Note"` and `"text"`
are persisted wire names, so keep them stable across releases.

### 3. Initialize the stack

Register your model, choose a persistent store location, and bind that store to
a remote zone. Initialization opens the local store synchronously and can throw;
handle setup failures at your app's startup boundary.

```swift
import CloudKitData
import CloudKitDataStack
import Foundation

@MainActor
func makeNotesStack(
  transport: CloudDataTransportConfiguration = .offline
) throws -> CloudKitDataStack {
  let directory = URL.applicationSupportDirectory
    .appendingPathComponent("MyNotes", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )

  let store = CloudDataStoreConfiguration(
    id: .init(rawValue: "notes"),
    location: .file(directory.appendingPathComponent("Notes.store")),
    remoteZone: .init(
      databaseScope: .private,
      zoneID: .init(zoneName: "notes-zone")
    )
  )

  return try CloudKitDataStack(
    schema: CloudDataSchema(models: [Note.self]),
    stores: CloudDataStoreDirectory(
      knownStores: [store],
      engineStateDirectoryURL: directory.appendingPathComponent("SyncState")
    ),
    transport: transport
  )
}
```

The configuration has a few different identities:

| Value | Purpose |
| --- | --- |
| `zoneDomain: "notes"` | Logical grouping for models in one `CloudDataSchema`; it is not the remote zone name. |
| Store ID `"notes"` | Your app's key for retrieving this local store. |
| Zone name `"notes-zone"` | The CloudKit custom zone for this store. Its owner defaults to `.currentUser` for the private database. |
| `Notes.store` / `SyncState` | Persistent local content/outbox and transport state locations. |

Keep these identifiers and paths stable across launches. For previews or
disposable tests, replace `.file(...)` with `.inMemory`.

### 4. Start and use the store

Run this from an async, throwing startup function on `@MainActor`. Keep `stack`
in your app's session owner for as long as you use its stores; create it once,
rather than in a view's `body`.

```swift
let stack = try makeNotesStack()
await stack.start()

if let store = stack.store(for: .init(rawValue: "notes")) {
  try store.transaction { transaction in
    try transaction.insert(Note(text: "Hello CloudKitData"))
  }

  let context = ModelContext(store.modelContainer)
  let notes = try context.fetch(FetchDescriptor<Note>())
  print(notes.map(\.text))

  try store.transaction { transaction in
    let notes = try transaction.modelContext.fetch(FetchDescriptor<Note>())
    if let note = notes.first {
      note.text = "Updated locally"
      try transaction.synchronize(note)
    }
  }
}
```

The initializer makes local reads and writes available. `start()` performs
startup recovery and starts the selected transport; it does **not** wait for
all devices to sync. With `.offline`, changes remain in the durable outbox
until you reopen the stack with CloudKit transport enabled.

Use `store.transaction` for synchronized writes: `insert` queues a new record,
`synchronize` queues an edited model, and `delete` queues deletion of an existing
synced record. A thrown error rolls back local content and queued changes
together. Calling `ModelContext.save()` directly does not queue synchronization.
See [Integration](Documentation/Integration.md#first-local-store) for rollback
and deletion details.

For SwiftUI, pass this store's container with
`.modelContainer(store.modelContainer)` and read with `@Query`. Keep writes in
store transactions; do not enable SwiftData's automatic CloudKit integration
on the same store. Observe `stack.observation` for local readiness, pending work,
and transport status.

## Enable CloudKit

After local storage works:

1. Add your app's **iCloud → CloudKit** capability and select a container. Add
   **Push Notifications**; on iOS, also enable **Background Modes → Remote
   notifications**.
2. Create the stack with that container identifier instead of the offline
   default:

   ```swift
   let stack = try makeNotesStack(
     transport: .cloudKit(
       containerIdentifier: "iCloud.com.example.MyNotes",
       databaseScopes: [.private]
     )
   )
   await stack.start()
   ```

3. Provision record types, field types, and required query indexes in CloudKit's
   Development environment. Deploy the schema to Production before distributing
   a Production-signed build. This package does not deploy the server schema.

Use this configuration **instead of** the offline startup above, preserving
the same store and zone identities. Replace the example container identifier
with your own. Shared databases need an explicit zone owner and app-owned
sharing flows; see [Integration](Documentation/Integration.md#enable-cloudkit).

## Try the runnable example

From a checkout of this repository:

```sh
swift run --package-path Examples/Notes Notes
```

The [standalone Notes consumer](Examples/Notes) uses a disposable offline store
and checks insert, reopen, update, rollback, and deletion. It requires no iCloud
account and does not demonstrate server synchronization.

## Further reading

- [Connect an app and understand the sync contract](Documentation/Integration.md)
- [Relationships, assets, accounts, and transactions](Documentation/Usage.md)
- [Development and release verification](CONTRIBUTING.md)

Pre-1.0: API and persistence changes require explicit compatibility review.
Signed multi-device CloudKit verification remains a release gate; offline tests
are not evidence of server convergence. Licensed under [Apache 2.0](LICENSE).
