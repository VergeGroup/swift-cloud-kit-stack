# Notes

A standalone macOS consumer with its own SwiftPM manifest. It imports only the
two public library products, not internal test fixtures. Run from the repo root:

```sh
swift run --package-path Examples/Notes Notes
```

The default run uses a disposable directory and verifies insert, update,
durable outbox, rollback, reopen, and deletion. It never contacts CloudKit or
touches your app's stores. A failure throws and exits nonzero.

To check a restart across processes using a dedicated directory:

```sh
swift run --package-path Examples/Notes Notes seed /path/to/sample-store
swift run --package-path Examples/Notes Notes verify /path/to/sample-store
```

`seed` refuses a nonempty directory. `verify` reads and checks the existing
content and pending work without adding a note. These commands can also check
a store across package versions if the consumer model/module is kept identical.
See [Integration](../../Documentation/Integration.md) before enabling CloudKit
in a signed app.
