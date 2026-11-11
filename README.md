# CloudKitData

Explicit CloudKit synchronization for application-owned SwiftData models.
Declare stable wire keys on your models; commit local changes and sync intent
together. CloudKit transport can be offline without disabling local storage.

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

`CloudKitData` provides model macros and schema mapping. `CloudKitDataStack`
adds SwiftData stores, a durable outbox, private/shared CloudKit synchronization,
relationships, assets, and observable sync status.

- [Run the independent Notes consumer](Examples/Notes)
- [Connect an app and understand the sync contract](Documentation/Integration.md)
- [Relationships, assets, accounts, and transactions](Documentation/Usage.md)
- [Development and release verification](CONTRIBUTING.md)

Pre-1.0: API and persistence changes require explicit compatibility review.
Signed multi-device CloudKit verification remains a release gate; offline tests
are not evidence of server convergence. Licensed under [Apache 2.0](LICENSE).
