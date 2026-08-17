#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIR/Info.plist")"
ARM_BUILD_DIR="$SCRIPT_DIR/.build/arm64-apple-macosx/release"
INTEL_BUILD_DIR="$SCRIPT_DIR/.build/x86_64-apple-macosx/release"
APP_DIR="$SCRIPT_DIR/.build/InfraPulse.app"
ZIP_PATH="$SCRIPT_DIR/.build/InfraPulse-$VERSION.zip"
LAUNCH_AGENT_PATH="$SCRIPT_DIR/.build/com.infrapulse.plist"

SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/private/tmp/aws-login-swift-module-cache}"
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/aws-login-clang-module-cache}"
export SWIFT_MODULECACHE_PATH CLANG_MODULE_CACHE_PATH

swift build -c release
swift build -c release --arch x86_64
rm -rf "$APP_DIR" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create \
    "$ARM_BUILD_DIR/InfraPulse" \
    "$INTEL_BUILD_DIR/InfraPulse" \
    -output "$APP_DIR/Contents/MacOS/InfraPulse"
cp -R "$ARM_BUILD_DIR/InfraPulse_InfraPulse.bundle" "$APP_DIR/"
cp "$SCRIPT_DIR/Sources/InfraPulse/Resources/darkAppIcon.png" "$APP_DIR/Contents/Resources/"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/InfraPulse"

sed \
    -e "s|__APP_PATH__|/Applications/InfraPulse.app/Contents/MacOS/InfraPulse|g" \
    "$SCRIPT_DIR/com.infrapulse.plist.template" > "$LAUNCH_AGENT_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
(cd "$SCRIPT_DIR/.build" && zip -q "$ZIP_PATH" "$(basename "$LAUNCH_AGENT_PATH")")
shasum -a 256 "$ZIP_PATH"
echo "$ZIP_PATH"
