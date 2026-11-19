# MacPulse Pro

[![CI](https://github.com/JustKrisCode/MacPulsePro/actions/workflows/ci.yml/badge.svg)](https://github.com/JustKrisCode/MacPulsePro/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A native macOS system monitor, diagnostics tool and **safe** optimizer, built with Swift 6 and SwiftUI.
It measures what macOS actually exposes, labels every value with its provenance (measured, estimated, inferred or
unavailable), and never deletes or terminates anything without validated, explicit confirmation.

- **SwiftUI app** with 11 sections, Swift Charts history, dark and light mode, and keyboard shortcuts
- **Menu bar companion** showing configurable live metrics
- **`macpulse` CLI** with the same engine and safety logic as the app, plus JSON output and exit codes for scripting
- **Opt-in background monitor** (a per-user LaunchAgent), SQLite history with retention, and explainable alerts
- No third-party dependencies, no network access, no administrator rights

## Requirements

- macOS 14 or later (developed and tested on macOS 27.2, Apple M4)
- Xcode 16+ / Swift 6 toolchain to build

## Build, test, install

```sh
swift test                      # 90 tests: safety, parsers, analysis, persistence, live collectors, overhead
scripts/build-app.sh            # → build/MacPulse Pro.app  (bundles the CLI at Contents/MacOS/macpulse)
UNIVERSAL=1 scripts/build-app.sh  # arm64 + x86_64 (Intel)
scripts/install.sh              # → ~/Applications/MacPulse Pro.app and ~/.local/bin/macpulse (no sudo)
```

During development: `swift run macpulse status` or `swift run MacPulseApp`.
Set `MACPULSE_HOME=/some/dir` to keep history and config out of `~/Library/Application Support`.

## Uninstall

```sh
scripts/uninstall.sh              # stops/removes the monitor, the app and the CLI link; keeps history
scripts/uninstall.sh --purge-data # also deletes history, configuration and logs
```

Manual equivalent: `macpulse monitor uninstall`, delete `~/Applications/MacPulse Pro.app`, `~/.local/bin/macpulse`,
`~/Library/Application Support/MacPulsePro` and `~/Library/Logs/MacPulsePro`.

## CLI

```text
macpulse status                     health score, key metrics, top processes, warnings (exit 3 if warnings)
macpulse doctor                     metric availability matrix, permissions, collector overhead
macpulse cpu | memory | gpu | thermal | battery
macpulse monitor [--interval 2]     live terminal dashboard
macpulse monitor install|uninstall|status|run
macpulse history [--hours 24] [--metric cpu] [--csv]
macpulse events                     recorded alerts
macpulse recommend [--with-storage] ranked, evidence-based recommendations
macpulse disk analyze [--personal]  categorized candidates with IDs (read-only)
macpulse disk clean --select ID,ID  dry run (default)
macpulse disk clean --select ID,ID --mode trash|delete --apply   validated cleanup after confirmation
macpulse disk clean --all-safe ...  every SAFE, unblocked item
macpulse disk large [PATH] [--min-size 2GB]
macpulse disk duplicates PATH
macpulse disk history               cleanup audit log
macpulse processes [--sort cpu|memory|runtime] [--filter TEXT] [--limit N]
macpulse processes tree [--pid PID]
macpulse processes inspect PID
macpulse processes terminate PID [--force]
macpulse report --format markdown|json|csv|html --output FILE [--with-storage]
macpulse config show | set KEY VALUE | path | reset
```

Global options are `--json`, `--no-color` (`NO_COLOR` is also honored) and `--yes` for non-interactive confirmation.
Exit codes: `0` ok, `1` failure, `3` warnings present, `64` usage error, `69` unavailable, `75` busy (a cleanup is
already running), `77` refused by the safety policy or by permissions. With `--json`, errors are printed as
`{"error":{"code","message"}}`.

## Configuration

`~/Library/Application Support/MacPulsePro/config.json`. Keys missing from the file use their defaults, and
out-of-range values are clamped.

| Key | Default | Meaning |
|---|---|---|
| `sampleIntervalSeconds` | 60 | Background monitor interval (minimum 10) |
| `processSampleEvery` | 5 | Record top processes every N samples |
| `reduceSamplingOnBattery` | true | Double the interval on battery |
| `retentionDays` / `maxSampleRows` | 14 / 100000 | History limits (cleanup audit log: 365 days) |
| `notificationsEnabled` | false | Alert notifications (opt-in) |
| `notificationCooldownMinutes` | 60 | Minimum gap between alerts of the same kind |
| `uiRefreshSeconds` | 2 | App refresh while the window is open |
| `menuBarMetrics` | `["cpu","memory"]` | Any of `cpu, memory, gpu, swap, thermal, disk` |
| `thresholds.*` | see `macpulse config show` | Low disk, swap growth, sustained CPU, runaway process, memory growth |

Example: `macpulse config set thresholds.lowDiskFreePercent 12`

## Measured overhead (Apple M4, release build)

| Scenario | CPU | Memory |
|---|---|---|
| Light sample (monitor tick, no process table) | ~15–20 ms per sample | — |
| Full sample incl. ~800 processes | ~25–80 ms per sample | — |
| CLI live monitor, 2 s interval, full process table | ~2% of one core | ~25 MB |
| App window open on Overview, 2 s refresh | ~2.7% of one core | ~125 MB |
| Background monitor, 60 s interval | <0.1% of one core | one SQLite row per minute |

Run `macpulse doctor` to see the per-collector timings on your own machine.

## Known limitations

See [docs/METRICS.md](docs/METRICS.md) for the full matrix. In short:

- **CPU and GPU die temperatures are not shown.** They require private SMC/HID interfaces. The thermal *state*
  from `ProcessInfo.thermalState` is the supported signal.
- **GPU utilization and per-process GPU time** come from IORegistry driver statistics (`IOAccelerator`
  `PerformanceStatistics` and the AGX user-client `AppUsage` counters). The values are real, but Apple does not
  document these interfaces, so they are labelled *measured (undocumented source)*. GPU power and per-process GPU
  memory need `sudo powermetrics` and are not collected.
- **Other users' processes** (root daemons) show no CPU or memory figures without root. MacPulse never asks for root.
- **APFS snapshot sizes** need root, so only snapshot names and dates are listed.
- **APFS clones**: tree sizes count allocated blocks per file, so cloned data can be overstated. Large-file and
  duplicate views use the clone-aware private size (`ATTR_CMNEXT_PRIVATESIZE`).
- Folders protected by macOS privacy controls (Safari, Mail, Trash, Downloads) are analyzed only when access is
  granted. MacPulse does not try to bypass these controls.
- **MetricKit** reports only the app's own daily diagnostics, so it is not used.
- Cache-ownership ("in use") detection matches bundle IDs and process names. A tool that runs as a generic
  interpreter (for example npm running as `node`) may not be detected; those caches are rebuildable by design.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Metric availability matrix](docs/METRICS.md)
- [Safety and threat model](docs/SAFETY.md)
- [Health score method](docs/HEALTH_SCORE.md)

## Privacy

MacPulse Pro makes no network connections and collects no telemetry. All history, configuration and the cleanup
audit log stay in `~/Library/Application Support/MacPulsePro` (file mode 0600). Process arguments that look like
credentials are redacted before they are displayed, and reports never include process arguments.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md), and report security issues privately as
described in [SECURITY.md](SECURITY.md). This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 Kristiyan Kiryazov.

MacPulse Pro is provided as is. It is designed to be conservative, but you are responsible for the cleanup and
termination actions you confirm.

