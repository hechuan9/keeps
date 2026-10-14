#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/app/Keeps Debug.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build --arch arm64 >&2
BIN_DIR="$(swift build --arch arm64 --show-bin-path)"
KEEPS_API_RESOURCES="$BIN_DIR/KeepsAPI_KeepsAPI.bundle"
[[ -d "$KEEPS_API_RESOURCES" ]]

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
cp "$BIN_DIR/PhotoAssetManager" "$MACOS_DIR/Keeps"
chmod +x "$MACOS_DIR/Keeps"
cp "$ROOT_DIR/Sources/PhotoAssetManager/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
MARKETING_VERSION="$(awk '$1 == "MARKETING_VERSION" { print $3 }' "$ROOT_DIR/Version.xcconfig")"
BUILD_NUMBER="$(awk '$1 == "CURRENT_PROJECT_VERSION" { print $3 }' "$ROOT_DIR/Version.xcconfig")"
[[ -n "$MARKETING_VERSION" && -n "$BUILD_NUMBER" ]]
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.keeps.debug" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Keeps Debug" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Keeps" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Sources/PhotoAssetManager/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp -R "$KEEPS_API_RESOURCES" "$RESOURCES_DIR/"
bash "$ROOT_DIR/scripts/bundle_ai_runtime.sh" "$RESOURCES_DIR"

# SwiftPM signs the executable alone; the assembled application needs a bundle signature.
codesign --force --sign - "$APP_DIR" >&2
codesign --verify --deep --strict "$APP_DIR" >&2

echo "$APP_DIR"
