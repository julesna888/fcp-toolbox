#!/bin/bash
# Builds a universal (Intel + Apple Silicon) "FCP Toolbox.app" and a .dmg in dist/.
# Usage: scripts/build_app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="dist/FCP Toolbox.app"
DMG="dist/FCP-Toolbox-$VERSION.dmg"

swift build -c release --arch arm64 --arch x86_64

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/FCPToolbox "$APP/Contents/MacOS/"
cp scripts/AppIcon.icns "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/g" scripts/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signature: no Apple Developer account needed, but the app is not notarized.
codesign --force --deep --sign - "$APP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "FCP Toolbox" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Built: $APP"
echo "Built: $DMG"
