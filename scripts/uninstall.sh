#!/bin/zsh
# Removes MacPulse Pro. Pass --purge-data to also delete history, configuration and logs.
set -euo pipefail

APP="$HOME/Applications/MacPulse Pro.app"
LINK="$HOME/.local/bin/macpulse"
PLIST="$HOME/Library/LaunchAgents/com.macpulse.monitor.plist"
DATA="$HOME/Library/Application Support/MacPulsePro"
LOGS="$HOME/Library/Logs/MacPulsePro"

# 1. Stop and remove the background monitor (if installed).
if launchctl print "gui/$(id -u)/com.macpulse.monitor" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/com.macpulse.monitor" || true
fi
[[ -f "$PLIST" ]] && rm -f -- "$PLIST" && echo "Removed LaunchAgent"

# 2. Quit the app if running.
osascript -e 'tell application id "com.macpulse.pro" to quit' >/dev/null 2>&1 || true

# 3. Remove the app (only if it is MacPulse Pro) and the CLI link (only if it points into it).
if [[ -d "$APP" ]]; then
  id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null || true)
  [[ "$id" == "com.macpulse.pro" ]] && rm -rf -- "$APP" && echo "Removed $APP"
fi
if [[ -L "$LINK" && "$(readlink "$LINK")" == *"MacPulse Pro.app"* ]]; then rm -f -- "$LINK"; echo "Removed $LINK"; fi

# 4. Optional data removal.
if [[ "${1:-}" == "--purge-data" ]]; then
  rm -rf -- "$DATA" "$LOGS"
  echo "Removed history, configuration and logs"
else
  echo "Kept data in: $DATA (run with --purge-data to remove it)"
fi
echo "If you enabled “Launch at login”, it is removed automatically with the app."
