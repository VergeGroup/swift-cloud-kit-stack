# Integrating CloudKitData

## Package dependency

Add `https://github.com/VergeGroup/swift-cloud-kit-stack` in Xcode or SwiftPM, then link
`CloudKitData` to your model module and `CloudKitDataStack` to your composition
root. The repository is private: every developer and CI checkout needs read
access. Never put access tokens in a package URL or manifest.

Until the first release tag, pin a reviewed commit rather than following a
moving branch. For example, replace `<commit>` with that commit's full SHA:

```swift
.package(
  url: "https://github.com/VergeGroup/swift-cloud-kit-stack",
  revision: "<commit>"
)
```

```swift
.product(name: "CloudKitData", package: "swift-cloud-kit-stack"),
.product(name: "CloudKitDataStack", package: "swift-cloud-kit-stack"),
```

The deployment floors are iOS 17 and macOS 14. The package uses Swift 6 language
mode and SwiftSyntax 602.x. Development verification uses Xcode 26.6 / Swift
6.3.x; the manifest's tools version is not a claim that every older Swift 6
compiler and SwiftData runtime has been exercised. CI records its actual Xcode
and Swift versions. There is no Linux or public CloudKit database support.

## First local store

The [Notes consumer](../Examples/Notes) is a separate SwiftPM package using only
public imports. It creates an offline store, commits a note and outbox entry,
then reopens both in another process. No signing or iCloud account is needed.

Keep one `CloudKitDataStack` alive for the session. Initialization opens the
known stores; `await stack.start()` independently starts transport and recovery.
Use `store.modelContainer` for SwiftUI queries and local reads. Do not enable
SwiftData's own automatic CloudKit integration on the same store.

All synchronized writes must go through `store.transaction` (or
`transactionWithFreshContext`) and explicitly call `insert`, `synchronize`,
`delete`, or `tombstone`. Direct `ModelContext.save()` calls are local-only.
Local content and outbox commit together; throwing rolls both back. Previously
held SwiftData models can still expose attempted property values after rollback:
read a fresh context for durable truth and restore UI snapshots if needed.

Deleting an unstaged local insert cancels its pending upload. If a deterministic
record name might already exist remotely, explicitly enqueue
`tombstone(Model.self, recordName:)` after deletion to preserve remote intent.
Record names must be unique across all model types within a zone and must not
change after insertion.

## Enable CloudKit

1. Configure the app's iCloud capability with a CloudKit container and the Push
   Notifications capability. On iOS enable the Remote notifications background
   mode. Use the same container identifier in `.cloudKit(...)`.
2. Bind each store to one exact database scope, zone name, and owner. A private
   zone uses `.currentUser`; a shared zone needs its actual named owner.
3. Replace `.offline` with `.cloudKit(containerIdentifier:databaseScopes:)` and
   start the stack. Keep container, zone, store, and subscription IDs stable
   across launches. Supply existing subscription IDs when migrating transport.
4. Provision record types, field types, and required query indexes in the
   Development environment, then deploy the schema to Production before a
   Production-signed build. This package does not deploy CloudKit schemas.

`zoneDomain` is a logical schema partition, not the remote zone name. Each
schema accepts one domain; use separate stacks for unrelated domains. The
stack routes private/shared custom zones but does not create or accept CKShare
invitations. Sharing UI and permissions remain app responsibilities.

See Apple's [CKSyncEngine documentation](https://developer.apple.com/documentation/cloudkit/cksyncengine)
for entitlement, delivery, and scheduling requirements. Background delivery and
cross-device convergence cannot be demonstrated by the offline sample.

## Conflict and recovery contract

The generated importer uses **record-level local-pending-wins**, not field-level
merging or a CRDT. Domain-specific conflict/deletion policy belongs in
`CloudDataStorePolicy`. Relationships are repaired after out-of-order imports
within the same exact store route; tree invariants remain the app's concern.

Account changes fail closed: transport stops, while local stores remain usable.
Decide whether retained data may sync to the reported account before calling
`resumeTransportAfterAccountChange()`. Never automatically upload retained
private data to a different account. If account policy replaces stores, create
a new stack after that work.

Use `stack.observation` for readiness, pending work, and diagnostic summaries.
Transport availability is not proof that all devices have converged. Retain
local data on errors; store deletion/reset requires explicit app policy.

Asset-enabled schemas require idempotent filesystem hooks. Incoming temporary
files are read-only and must be copied, not moved. See [Usage](Usage.md) for
staging, retry, and acknowledgement semantics. Apps sharing a SQLite store
across processes must provide coordination hooks and use fresh-context writes.

## Compatibility and migration

This extraction retains `CloudKitData`, `CloudKitDataMacros`, and
`CloudKitDataStack` module names, all persistent system model names, wire keys,
schema fingerprint computation, engine-state encoding, and consumer APIs.
Changing the repository or package identity alone must not reset stores or
change remote identities. MuApps now supplies its own model, routing, conflict,
sharing, and retention policies as an external consumer.

Pin revisions during the pre-1.0 period. Review API, local SwiftData schema,
remote wire schema, and engine-state compatibility separately for each update.
Do not rename persisted models/modules, fields, or CloudKit identities merely
to match a new package name. `schema.version` and `replayGeneration` are not
automatic data migrations; custom SwiftData migration plans are not currently
exposed by the stack. Back up and test existing stores before schema changes.

Before release, exercise signed devices with two iCloud accounts: private and
shared changes, offline edits/reconnect, conflicting edits, assets, share
acceptance/revocation, account switching, and Development/Production containers.
These are explicit manual release gates, not claims made by the unit suite.
