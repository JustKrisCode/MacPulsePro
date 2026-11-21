#!/bin/zsh
# Measures the release app's own CPU time and memory footprint on one section for 60 s.
#   scripts/bench-app.sh [section]   (overview, cpu, gpu, processes, energy, …)
set -euo pipefail
ROOT=${0:A:h:h}; cd "$ROOT"
SECTION=${1:-overview}
swift build -c release --product MacPulseApp >/dev/null
BIN=$(swift build -c release --show-bin-path)/MacPulseApp
HOME_DIR=$(mktemp -d)
MACPULSE_HOME=$HOME_DIR MACPULSE_START_SECTION=$SECTION "$BIN" >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf -- "$HOME_DIR"' EXIT
sleep 20
to_s() { awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }' <<< "$1"; }
A=$(to_s "$(ps -o time= -p $PID | xargs)")
sleep 60
B=$(to_s "$(ps -o time= -p $PID | xargs)")
FP=$(footprint $PID 2>/dev/null | awk '/phys_footprint:/{print $2, $3; exit}')
printf "section=%s cpu=%.2fs/60s (%.1f%% of one core) footprint=%s\n" "$SECTION" "$(($B - $A))" "$(( ($B - $A) / 60 * 100 ))" "$FP"
