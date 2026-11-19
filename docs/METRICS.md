# Metric availability matrix

Verified on macOS 27.2 (build 26B123), Apple M4 (4P+6E), as a non-admin user, without Full Disk Access.
`macpulse doctor` prints this matrix live for the current machine.

| Metric | Status | Provenance | Source |
|---|---|---|---|
| CPU total, user/system | ✓ | measured | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` deltas |
| Per-core utilization | ✓ | measured | same, per logical CPU |
| P/E core mapping | ✓ (Apple Silicon) | measured | IODeviceTree `cpus/*` `cluster-type` + `logical-cpu-id` |
| Load averages | ✓ | measured | `getloadavg` |
| Memory: app / wired / compressed / cached / free / active / inactive | ✓ | measured | `host_statistics64(HOST_VM_INFO64)` |
| Memory pressure level | ✓ | measured | `kern.memorystatus_vm_pressure_level` |
| Swap used/total, swap-ins/outs | ✓ | measured | `vm.swapusage`, VM statistics |
| Swap growth rate | ✓ (needs ≥10 min of history) | estimated | least-squares fit over the last hour |
| Per-process CPU %, CPU time, threads | ✓ own user / ✗ other users | measured | `proc_pidinfo(PROC_PIDTASKINFO)` (mach ticks → ns via timebase) |
| Per-process memory (physical footprint) | ✓ own user / ✗ other users | measured | `proc_pid_rusage(RUSAGE_INFO_V6)` |
| Per-process energy (cumulative) and power (W) | ✓ own user / ✗ other users | measured-undocumented | `proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj` deltas (kernel accounting, mainly CPU-side) |
| Per-process wakeups/s | ✓ own user | measured | `ri_pkg_idle_wkups + ri_interrupt_wkups` deltas |
| Process start time (PID-reuse identity) | ✓ all | measured | `sysctl(KERN_PROC)` |
| Process arguments, working directory | ✓ own user | measured | `KERN_PROCARGS2`, `PROC_PIDVNODEPATHINFO` |
| Code-signature status | ✓ | measured | `SecStaticCodeCheckValidity` |
| GPU device / renderer / tiler utilization | ✓ | measured-undocumented | IOAccelerator `PerformanceStatistics` |
| GPU driver memory in use | ✓ | measured-undocumented | IOAccelerator `PerformanceStatistics` |
| Per-process GPU time (Metal, incl. browser WebGL/WebGPU) | ✓ (Apple Silicon) | measured-undocumented | AGX user-client `AppUsage.accumulatedGPUTime` (ns; per-process sums matched device utilization within ~3 points) |
| GPU power, per-process GPU memory | ✗ | unavailable | needs `sudo powermetrics` or private APIs |
| Thermal pressure state | ✓ | measured | `ProcessInfo.thermalState` |
| CPU speed limit | on demand, only if recorded | measured | `pmset -g therm` |
| Throttling indicator | ✓ | inferred | thermal state ≥ serious or speed limit < 100% |
| CPU/GPU die temperature | ✗ | unavailable | SMC/HID sensors are private |
| Battery temperature | only if published | measured-undocumented | AppleSmartBattery `Temperature` (not published on the test machine) |
| Battery charge, cycles, design/nominal capacity | ✓ | measured | IOPowerSources, AppleSmartBattery |
| Battery health % | ✓ | estimated | NominalChargeCapacity ÷ DesignCapacity |
| Battery power (W) | ✓ | estimated | voltage × amperage |
| Volume capacity / free | ✓ | measured | `statfs`, `URLResourceValues` |
| Purgeable space | ✓ (refreshed every 10 min) | estimated | `availableForImportantUsage − available` |
| APFS containers/volumes | on demand | measured | `diskutil apfs list -plist` |
| Local snapshots (names/dates) | on demand | measured | `tmutil listlocalsnapshots /` |
| Snapshot sizes | ✗ | unavailable | needs root |
| Allocated vs. logical size | ✓ | measured | `fts` + `st_blocks` (hard links counted once) |
| Clone-aware private size (per file) | ✓ APFS | measured | `getattrlist(ATTR_CMNEXT_PRIVATESIZE)` |
| Folder growth over time | ✓ (on demand / daily in monitor) | measured | repeated `fts` allocated-size scans stored in SQLite |
| Swap file size on disk | ✓ | measured | `vm.swapusage` total |
| Slowdown diagnosis, resource pressure | ✓ | inferred | rules over the measured signals above (documented in code) |
| MetricKit | ✗ (not applicable) | — | reports only the app's own diagnostics, daily |
