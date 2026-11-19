# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Automatic cleanup (opt-in)**: scheduled removal of SAFE, idle (≥24 h) developer caches/logs (browser and app
  caches optional), driven by the background monitor or the open app; preview, run-now, Settings UI,
  `macpulse autoclean`, audit entries with `auto-` run ids, events and optional notifications.
- **Slowdown detective** (`macpulse why`, app ⌘Y, menu bar "Why slow?"): bottleneck, per-resource pressure, baseline
  comparison against this Mac's history, ranked causes with evidence and suggestions.
- **Energy**: per-process and per-app power (W) and wakeups/s from kernel energy accounting (`rusage v6`); new Energy
  section, Power/Wakeups columns in Processes, `macpulse energy`, `--sort energy|wakeups`.
- **Disk growth tracker**: folder-size scans stored in SQLite (60 kept), comparison including swap files and
  unattributed system change; `macpulse disk growth`, Storage › Growth tab; daily scan in the background monitor.
- **Workload gate**: `macpulse ready` and `macpulse run --when-ready -- COMMAND` (exec, no shell; job exit code preserved).
- MIT license, contributing guide, security policy, code of conduct, issue/PR templates and CI workflow.
- 20 new tests (110 total).
- Slowdown detective judges swapping by MB/min (16 KB pages), so light background swapping is no longer "high impact"; the all-clear icon only shows without high-impact causes.

### Fixed
- `UInt64 → Double` conversions via `map(Double.init)` resolved to `Double(bitPattern:)`, so history and baseline
  values showed as "0 B". Every occurrence is replaced and covered by a regression test.

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
