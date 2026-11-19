#!/bin/zsh
# Installs MacPulse Pro for the current user only (no administrator rights):
#   ~/Applications/MacPulse Pro.app   and   ~/.local/bin/macpulse -> bundled CLI
set -euo pipefail

ROOT=${0:A:h:h}
SRC="$ROOT/build/MacPulse Pro.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/MacPulse Pro.app"
BIN_DIR="$HOME/.local/bin"

[[ -d "$SRC" ]] || { echo "Build first: scripts/build-app.sh"; exit 1; }
mkdir -p "$DEST_DIR" "$BIN_DIR"

if [[ -e "$DEST" ]]; then
  # Only replace a previous MacPulse install (verified by bundle identifier).
  existing=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist" 2>/dev/null || true)
  [[ "$existing" == "com.macpulse.pro" ]] || { echo "$DEST exists and is not MacPulse Pro; not touching it."; exit 1; }
  rm -rf -- "$DEST"
fi
ditto "$SRC" "$DEST"

LINK="$BIN_DIR/macpulse"
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
  echo "$LINK exists and is not a symlink; skipping CLI link."
else
  ln -sfn "$DEST/Contents/MacOS/macpulse" "$LINK"
  echo "CLI linked: $LINK"
fi

echo "Installed: $DEST"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "Add to your shell profile:  export PATH=\"$BIN_DIR:\$PATH\"";; esac
echo "The background monitor is NOT enabled. Opt in from the app (Monitoring) or: macpulse monitor install"
