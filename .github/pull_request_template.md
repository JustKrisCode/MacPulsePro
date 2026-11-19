## What & why

## How it was verified
- [ ] `swift test` passes (Swift 6 strict concurrency, no new warnings)
- [ ] Manually checked in the CLI and/or app (screenshots for UI changes)

## Safety checklist
- [ ] No fabricated values; new metrics carry the correct `Provenance` and are listed in `docs/METRICS.md`
- [ ] Destructive paths still go through dry run → confirmation → `PathGuard` → revalidation → audit
- [ ] Destructive tests only touch `TempDir` fixtures
- [ ] No shell execution, private APIs, root requirements or network access
- [ ] `CHANGELOG.md` updated
