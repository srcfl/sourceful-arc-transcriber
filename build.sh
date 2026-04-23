#!/bin/bash
set -euo pipefail

# Bundle filename is "Arc Transcriber.app" so Finder shows the right
# label; CFBundleExecutable stays "Transcriber" (the SPM target's
# binary name).
BIN_NAME="Transcriber"
BUNDLE_NAME="Arc Transcriber.app"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

BUILD_CONFIG="release"
BIN_PATH=".build/${BUILD_CONFIG}/${BIN_NAME}"
APP_DIR="build/${BUNDLE_NAME}"

echo "→ Compiling…"
swift build -c "$BUILD_CONFIG"

echo "→ Assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if [[ -f Resources/iconfile.icns ]]; then
    cp Resources/iconfile.icns "$APP_DIR/Contents/Resources/iconfile.icns"
fi

echo "→ Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR"

echo
echo "Built: $APP_DIR"
echo "Run:   open \"$APP_DIR\""
