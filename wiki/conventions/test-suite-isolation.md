# Convention: Test suite isolation

The synthetic suite (`swift run adevcontainerTests`) must never read or delete a developer's real recovery, resume, session, or staging state.

## Rules

- On macOS, Foundation's `NSTemporaryDirectory()` / `FileManager.temporaryDirectory` ignore the `TMPDIR` env var. `TMPDIR=…` does **not** isolate the suite.
- Every product temp or retained-state root (recovery sessions, resume indexes, guest staging, clone recovery checkouts) goes through `StateDirectories` (`Sources/ADevContainerLib/Support/StateDirectories.swift`). New roots must use it, never `FileManager.temporaryDirectory` or Application Support directly. No user-facing override exists.
- The test runner sets `StateDirectories.isolatedRoot` to a per-run scratch directory, removed on exit.
- The test binary re-launches itself for TTY and provider-crash probes. Per-run setup in `Tests/adevcontainerTests/main.swift` goes **after** the probe branches, so probes exit before creating (and leaking) a root.
- `TemporaryDirectory.*` dirs in `$TMPDIR` come from SwiftPM (`swift build` / `swift run`), not the product or the suite.

## Related

- [CLI runtime boundary — tests](cli-runtime-boundary.md#features-runner)
- [Private data placeholders](private-data-placeholders.md)
