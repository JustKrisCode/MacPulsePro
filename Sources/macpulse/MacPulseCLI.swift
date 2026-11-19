import Darwin
import Foundation
import MacPulseCore

@main
struct MacPulseCLI {
    static func main() async {
        let args = Args(Array(CommandLine.arguments.dropFirst()))
        Style.configure(disable: args.has("no-color") || args.has("json"))
        signal(SIGPIPE, SIG_IGN)
        do {
            let code = try await Commands(args: args).dispatch()
            exit(code)
        } catch let e as MacPulseError {
            report(e, args)
            exit(e.exitCode)
        } catch {
            report(.failed("\(error)"), args)
            exit(1)
        }
    }

    static func report(_ e: MacPulseError, _ args: Args) {
        if args.has("json") {
            print(JSON.string(["error": ["code": e.code, "message": e.description]]))
        } else {
            printErr(Style.red("error[\(e.code)]") + ": " + e.description)
            if case .usage = e { printErr("Run 'macpulse help' for usage.") }
        }
    }
}

let helpText = """
MacPulse Pro — native macOS system monitoring, diagnostics and safe optimization.

USAGE
  macpulse <command> [options]

MONITORING
  status                         Health score, key metrics, top processes, warnings
  doctor                         Environment, permissions, metric availability, collector overhead
  cpu                            Per-core (P/E) usage, load, busiest processes
  memory                         Pressure, swap, compression, largest apps, growth findings
  gpu [--sample SEC]             GPU utilization and per-process GPU time
  thermal                        Thermal pressure, throttling indicators, power state
  battery                        Battery health and power information
  monitor [--interval SEC] [--count N]   Live dashboard (Ctrl-C to quit)
  monitor install|uninstall|status       Opt-in background monitor (LaunchAgent, no admin)
  monitor run                    Run the background monitor loop in the foreground
  history [--hours N] [--metric cpu|memory|swap|gpu|thermal|disk] [--csv]
  events [--hours N]             Alerts recorded by the background monitor
  recommend                      Ranked, evidence-based recommendations

INSIGHTS
  why                            Why is my Mac slow? Bottleneck, baseline comparison and named causes
  energy [--sample SEC]          Power per app (W) and CPU wakeups — what drains the battery
  ready [--cpu 60] [--allow-fair]          Exit 0 if the Mac has headroom for heavy work, 10 if not
  run --when-ready [--max-wait 30m] [--cpu 60] [--allow-fair] [--run-anyway] -- COMMAND …
                                 Start a heavy job only once the Mac is cool and has free memory

STORAGE
  disk analyze [--personal] [--no-protected]   Categorized cleanup candidates (read-only)
  disk clean [--select ID,ID | --all-safe] [--mode trash|delete] [--apply] [--yes]
                                 Dry run by default; --apply performs the cleanup after confirmation
  disk large [PATH] [--min-size 1GB]           Largest files (clone-aware sizes)
  disk duplicates PATH [--min-size 1MB]        Identical files by SHA-256
  disk history                   Cleanup audit log (estimated vs measured bytes)
  disk growth [--scan] [--since 7d] [--personal]   What grew on disk, incl. swap files
  autoclean [status|enable|disable|preview|run] [--every 7] [--mode delete|trash] [--categories …]
                                 Opt-in scheduled cleanup of SAFE caches/logs (idle ≥24 h, apps not running)

PROCESSES
  processes [--sort cpu|memory|energy|wakeups|runtime|pid|name] [--limit N] [--filter TEXT] [--all]
  processes tree [--pid PID]     Parent/child tree
  processes inspect PID          Details, arguments (secrets redacted), signature, ancestry
  processes terminate PID [--force] [--yes]    Graceful quit with pid-reuse protection

REPORTS & CONFIG
  report [--format markdown|json|csv|html] [--output FILE] [--with-storage]
  config show | config set KEY VALUE | config path | config reset
  version | help

GLOBAL OPTIONS
  --json        Machine-readable output (errors too)       --no-color   Disable ANSI colors
  --verbose     Extra diagnostics

EXIT CODES
  0 ok · 1 failure · 3 warnings present (status/why) · 10 not ready · 64 usage · 69 unavailable · 75 busy · 77 refused/permission
"""
