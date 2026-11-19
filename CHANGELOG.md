# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- MIT license, contributing guide, security policy, code of conduct, issue/PR templates and CI workflow.

## [1.0.0] — 2026-11-19

### Added
- `MacPulseCore` shared engine: CPU (per-core, P/E clusters), memory (pressure, swap, compression), GPU
  (IOAccelerator utilization, per-process GPU time), thermal state, battery/power, storage and process collectors,
  all with explicit provenance.
- Explainable health score and deterministic, ranked recommendation engine.
- Process analysis: app grouping, process tree, probable orphans, sustained-CPU runaways, memory-growth detection,
  duplicate instances, unusual unsigned activity.
- Safe storage cleanup: catalog-based candidates (SAFE/REVIEW/PROTECTED/UNKNOWN), PathGuard allowlist/denylist,
  inode revalidation, no-follow deletion, Trash by default, exclusive lock, cancellation, audit log, measured results.
- Large-file and duplicate finders with APFS clone-aware sizes.
- PID-reuse-safe graceful process termination with protected-process policy.
- Opt-in background monitor (per-user LaunchAgent), SQLite history with retention, explainable alerts, notifications.
- SwiftUI app with 11 sections, Swift Charts, menu bar companion, settings, report/history export.
- `macpulse` CLI with JSON output and scripting-friendly exit codes; Markdown/JSON/CSV/HTML reports.
- Build, install and uninstall scripts (no administrator rights); universal (arm64 + x86_64) build option.
- 90 tests (Swift Testing).
