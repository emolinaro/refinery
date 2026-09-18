#!/bin/bash
# Builds the release Refinery.app bundle (arm64, ad-hoc signed, LSUIElement).
#
# Usage: ./Scripts/build-app.sh
set -euo pipefail

if (( $# != 0 )); then
    echo "usage: ./Scripts/build-app.sh" >&2
    exit 64
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO_ROOT/.build/Refinery.app"
STAGING_APP="$REPO_ROOT/.build/.Refinery.app.new"

cd "$REPO_ROOT"
swift build -c release --product Refinery --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$BIN_DIR/Refinery" "$STAGING_APP/Contents/MacOS/Refinery"
cp "$REPO_ROOT/LICENSE" "$STAGING_APP/Contents/Resources/LICENSE"

cat > "$STAGING_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Refinery</string>
    <key>CFBundleIdentifier</key>
    <string>com.emolinaro.refinery</string>
    <key>CFBundleName</key>
    <string>Refinery</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 Refinery contributors</string>
</dict>
</plist>
PLIST

lipo "$STAGING_APP/Contents/MacOS/Refinery" -verify_arch arm64
codesign --force --sign - "$STAGING_APP"
rm -rf "$APP"
mv "$STAGING_APP" "$APP"

echo "built: $APP (arm64, ad-hoc signed)"
