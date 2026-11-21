# Contributing to MacPulse Pro

Thanks for your interest! Bug reports, metric-accuracy fixes and new safe cleanup rules are especially welcome.

## Development setup

- macOS 14+, Xcode 16+ (Swift 6 toolchain)
- No third-party dependencies

```sh
swift build                     # debug build of everything
swift test                      # full test suite
swift run macpulse status       # CLI
swift run MacPulseApp           # SwiftUI app (unbundled; notifications/login item need the .app)
scripts/build-app.sh            # release .app bundle in ./build
```

Use `MACPULSE_HOME=/tmp/mp` to keep history and configuration out of `~/Library/Application Support` while developing.

### Measuring overhead

```sh
scripts/bench-app.sh overview        # release app CPU/footprint over 60 s on a section
MACPULSE_PROFILE=1 MACPULSE_START_SECTION=gpu "$(swift build -c release --show-bin-path)/MacPulseApp"
```
Compare old and new builds side by side when the machine is busy; single runs are noisy.

### Visual check of the UI

The app has a developer snapshot mode that renders every section to PNG without Screen Recording permission:

```sh
MACPULSE_HOME=/tmp/mp MACPULSE_SNAPSHOT_DIR=/tmp/shots MACPULSE_SNAPSHOT_APPEARANCE=dark \
  "$(swift build --show-bin-path)/MacPulseApp"
# MACPULSE_SNAPSHOT_SCAN=1 also runs a (read-only) storage scan first
```

In snapshot mode the process list is reduced to macOS system processes and MacPulse itself, and the account name
and home folder are masked, so the images in `docs/screenshots/` do not reveal what else runs on the capturing Mac.
Storage scans (`MACPULSE_SNAPSHOT_SCAN=1`) are **not** scrubbed. Check those images before publishing them.

## Ground rules

These are the project's non-negotiables; PRs that break them will not be merged.

1. **No fabricated data.** Every user-facing value carries a `Provenance`. If macOS does not expose a metric through
   a supported interface, show it as unavailable — never estimate silently or invent numbers.
2. **Safety first.** Read-only by default; destructive actions require a dry run, explicit confirmation, `PathGuard`
   validation and inode revalidation. Never add a cleanup rule based only on a folder name or size. New rules need a
   clear owner, consequence text and a test. See [docs/SAFETY.md](docs/SAFETY.md).
3. **One engine.** Measurement, analysis and safety logic live in `MacPulseCore`. The CLI and the app stay thin.
4. **No shell.** External tools run via `CommandRunner` with absolute paths and argv arrays.
5. **Low overhead.** Nothing expensive on the polling path. Measure with `macpulse doctor` and the overhead test.
6. **No private APIs, no root, no SIP/TCC bypasses, no network access.**
7. **Tests.** New behavior needs tests. Destructive tests must operate only inside `TempDir` fixtures; never against
   real user data. Use `MockCommandRunner` for tool output.

## Pull requests

- Keep PRs focused; describe *what* and *why*, and how you verified it.
- `swift test` must pass under Swift 6 strict concurrency with no new warnings.
- Update `CHANGELOG.md` and the docs (`docs/METRICS.md` for any new metric) when behavior changes.

## Reporting bugs

Open an issue with your Mac model, macOS version, the command or screen involved, and the output of
`macpulse doctor --json` (review it before posting; it contains no personal data beyond hardware and OS info).
Security issues: see [SECURITY.md](SECURITY.md).
