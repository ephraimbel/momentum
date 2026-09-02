# Archived SwiftData migration fixture

`ArchivedRunningSchemaV1Build36.store` is an immutable SQLite store produced by the committed
Momentum 1.6.0 build-36 source at commit `8af1a7463a36eb9e356716ef4528168685a1136a`.
It was not generated from the current model classes.

- SHA-256: `79cf0cd02114c29ff2f0f291fc946e3f256f4f447a0006d86779f6f119a28e2c`
- Schema at export: unversioned/`SchemaV1`, version identifier 1.0.0
- Exported: 2026-09-01 on the iOS 26.0 simulator with Xcode 26.2
- Stable ID prefix: `B0360000-0000-0000-0000-…`

The graph deliberately includes a profile, race plan, completed planned run, linked workout, GPS
samples, photo blob, athlete memory, and an `AppNotification` written before its newer optional
navigation fields existed. The migration test copies the resource to a writable temporary directory;
never migrate or rewrite the checked-in fixture in place.

To replace this file, export from the exact committed shipping source in an isolated worktree, close
the test process so SQLite checkpoints its journal, verify `PRAGMA integrity_check`, update the hash
above, and review the fixture change as release data—not as a generated current-schema test asset.
