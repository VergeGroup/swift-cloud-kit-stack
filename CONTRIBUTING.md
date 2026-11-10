# Development

Use Xcode's Swift toolchain on macOS. No Tuist project or MuApps checkout is
required. `mise run setup` resolves dependencies; `mise run test` runs the
package tests, Release build, and independent public-API consumer.

```sh
swift test
swift build -c release
swift run --package-path Examples/Notes Notes
```

CI additionally builds both library products for a generic iOS Simulator with
`xcodebuild`. Existing source follows two-space indentation; keep formatting
changes scoped. There is no separate lint dependency: `git diff --check` and
Swift compiler diagnostics are the source gates. Use `actionlint` when changing
the GitHub Actions workflow.

The macro expansion suite uses XCTest; runtime suites use Swift Testing.
Consumer fixtures intentionally import the public modules from another target.
The Notes executable is a separate package and must not use `@testable`.

## Before publishing a release

- Run the macOS unit suite, Release build, and iOS Simulator build.
- Reopen a store written by the preceding version, including pending work.
- Review exported API changes and all persisted/wire format changes separately.
- Run the signed multi-device matrix in [Integration](Documentation/Integration.md).
- Record the tested Xcode/OS versions and limitations in the release notes.

Do not label an offline test as a CloudKit integration test. Do not tag 1.0
until the API and migration policy are ready and the signed-device gates pass.
