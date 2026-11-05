#!/bin/bash
# Builds a universal (Intel + Apple Silicon) "FCP Toolbox.app" and a .dmg in dist/.
# Usage: scripts/build_app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
# built in a temp folder: iCloud-synced folders (Documents) add attributes that make codesign fail
WORK="$(mktemp -d)"
APP="$WORK/FCP Toolbox.app"
DMG="$WORK/FCP-Toolbox-$VERSION.dmg"

swift build -c release --arch arm64 --arch x86_64

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/FCPToolbox "$APP/Contents/MacOS/"
cp scripts/AppIcon.icns "$APP/Contents/Resources/"
# English texts for plain SwiftUI Text("…"): written from Translations.swift so there is one list only
"$APP/Contents/MacOS/FCPToolbox" --dump-strings "$APP/Contents/Resources"
sed "s/__VERSION__/$VERSION/g" scripts/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signature: no Apple Developer account needed, but the app is not notarized.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "FCP Toolbox" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

rm -rf dist && mkdir -p dist
ditto "$APP" "dist/FCP Toolbox.app"
cp "$DMG" dist/
rm -rf "$WORK"
echo "Built: dist/FCP Toolbox.app"
echo "Built: dist/FCP-Toolbox-$VERSION.dmg"
