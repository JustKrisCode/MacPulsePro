# Architecture

```
Sources/
  MacPulseCore/            shared library — the only measurement and safety engine
    Support/               argv-only command runner, sysctl/mach helpers, provenance model, formatting
    Collectors/            CPU, memory, GPU, thermal/power, storage, processes, process inspector/controller
                           SystemSampler (actor) owns all stateful samplers
    Analysis/              trends (OLS, sustained-window), health score, process analyzer, recommendation engine
    Cleanup/               disk accounting (fts), PathGuard, catalog, scanner, cleaner, large/duplicate finders
    Persistence/           SQLite wrapper, HistoryStore (samples, process samples, events, cleanup audit), config
    Monitoring/            MonitorAgent (actor), alert rules, LaunchAgent manager, notifier
    Reporting/             Markdown / JSON / CSV / HTML reports
  macpulse/                CLI (argument parsing, tables, commands) — thin layer over MacPulseCore
  MacPulseApp/             SwiftUI app + MenuBarExtra — thin @MainActor @Observable layer over MacPulseCore
Tests/MacPulseCoreTests/   Swift Testing suites
scripts/                   build-app.sh, make-icon.swift, install.sh, uninstall.sh
```

## Principles

1. **One engine.** The CLI, the app and the background monitor all call `SystemSampler`, `HealthScorer`,
   `RecommendationEngine`, `CleanupScanner`/`Cleaner` and `ProcessController`. No front end has its own copy of the
   monitoring or safety logic.
2. **Provenance everywhere.** `Metric<T>` carries `measured | measured-undocumented | estimated | inferred | unavailable`,
   plus a source and a note. Unavailable data shows as unavailable. Nothing is filled in with fabricated values.
3. **Native interfaces first.** `host_processor_info`, `host_statistics64`, `sysctl` (`KERN_PROC`, `KERN_PROCARGS2`,
   `vm.swapusage`, `kern.memorystatus_vm_pressure_level`), libproc, IOKit, `ProcessInfo.thermalState`,
   `URLResourceValues`, `getattrlist`, `fts`, Security (code signatures) and ServiceManagement.
   Subprocesses (`pmset`, `diskutil`, `tmutil`, `launchctl`, `osascript`) run only on demand or rarely, always by
   absolute path, with an argv vector and a timeout.
4. **Swift 6 strict concurrency.** Stateful samplers are value types owned by the `SystemSampler` actor. The
   monitor loop is an actor. The UI model is `@MainActor`. Expensive work (scans, cleanup, inspection) runs in
   detached tasks.
5. **Cheap polling.** Hot-path samples use syscalls only. Volume capacity comes from `statfs`; the expensive purgeable
   estimate (served by macOS's cache-delete service) refreshes every 10 minutes. The process table is read every
   other UI tick, and only every sixth tick when just the menu bar is visible. Charts are downsampled to ≤150 points
   per series.

## Data flow

```
SystemSampler (actor) ──snapshot──▶ HistorySummary ─┐
      │                                            ├─▶ HealthScorer ─▶ HealthReport
      │                                            ├─▶ ProcessAnalyzer ─▶ findings
      │                                            └─▶ RecommendationEngine ─▶ ranked recommendations
      └─▶ MonitorAgent ──▶ HistoryStore (SQLite) ──▶ MonitorRules ──▶ events / notifications
CleanupScanner ─▶ StorageAnalysis ─▶ (user selection) ─▶ Cleaner (dry run ▶ confirm ▶ revalidate ▶ act ▶ audit)
```

## Persistence

`~/Library/Application Support/MacPulsePro/history.sqlite` (WAL mode, file mode 0600):

- `samples`: one compact row per monitor tick
- `process_samples`: only the top consumers, every N ticks
- `events`: alerts
- `cleanup_history`: the audit log, kept for 365 days

Retention by age and row count runs every 6 hours, followed by an incremental vacuum.
