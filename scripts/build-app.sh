#!/bin/zsh
# Builds "MacPulse Pro.app" (SwiftUI app + bundled `macpulse` CLI) into ./build.
#   CONFIG=debug scripts/build-app.sh      # debug build
#   UNIVERSAL=1 scripts/build-app.sh       # arm64 + x86_64 (Intel) binary
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
CONFIG=${CONFIG:-release}
VERSION=$(grep -o 'MacPulse Pro [0-9.]*' Sources/MacPulseCore/Reporting/Report.swift | head -1 | awk '{print $3}')
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "==> Building ($CONFIG ${ARCH_FLAGS[*]:-native})"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product macpulse
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product MacPulseApp
BIN=$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)

APP="$ROOT/build/MacPulse Pro.app"
# Only ever replaces this script's own output directory.
[[ "$APP" == "$ROOT/build/"* ]] || { echo "refusing to write outside $ROOT/build"; exit 1; }
rm -rf -- "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacPulseApp" "$APP/Contents/MacOS/MacPulsePro"
cp "$BIN/macpulse" "$APP/Contents/MacOS/macpulse"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacPulse Pro</string>
  <key>CFBundleDisplayName</key><string>MacPulse Pro</string>
  <key>CFBundleIdentifier</key><string>com.macpulse.pro</string>
  <key>CFBundleExecutable</key><string>MacPulsePro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>MacPulse Pro — local-only system monitor</string>
</dict>
</plist>
PLIST

echo "==> Generating icon"
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf -- "${ICONSET:h}"

echo "==> Ad-hoc code signing"
codesign --force --options runtime --sign - "$APP/Contents/MacOS/macpulse"
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built: $APP"
echo "CLI:   $APP/Contents/MacOS/macpulse"
