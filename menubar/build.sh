#!/bin/bash
# Builds IMD Worker.app and installs it in ~/Applications. ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="build/IMD Worker.app"
echo "→ compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -swift-version 5 Sources/*.swift \
    -framework SwiftUI -framework AppKit -framework ServiceManagement \
    -o "$APP/Contents/MacOS/IMDWorker"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "→ installing in ~/Applications…"
mkdir -p "$HOME/Applications"
pkill -x IMDWorker 2>/dev/null || true
rm -rf "$HOME/Applications/IMD Worker.app"
cp -R "$APP" "$HOME/Applications/"
echo "✓ ~/Applications/IMD Worker.app"
