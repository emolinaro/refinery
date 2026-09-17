#!/bin/bash
# Builds the release Refinery.app bundle (arm64, ad-hoc signed, LSUIElement)
# and copies it to the paths passed as arguments (if any).
#
# Usage: ./Scripts/build-app.sh [destination.app ...]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

cd "$REPO_ROOT"
swift build -c release --product Refinery --scratch-path "$BUILD_DIR"

APP="$BUILD_DIR/release/Refinery.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD_DIR/release/Refinery" "$APP/Contents/MacOS/Refinery"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <string>1.0.1</string>
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

codesign --force --sign - "$APP"

for DEST in "$@"; do
    TARGET="$(dirname "$DEST")/.$(basename "$DEST").new"
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    # Atomically replace even a running bundle: kill instances first.
    if pgrep -f "$DEST/Contents/MacOS/Refinery" >/dev/null 2>&1; then
        pkill -f "$DEST/Contents/MacOS/Refinery" || true
        sleep 1
    fi
    rm -rf "$DEST"
    mv "$TARGET" "$DEST"
    echo "installed: $DEST"
done

echo "built: $APP (arm64, ad-hoc signed)"
