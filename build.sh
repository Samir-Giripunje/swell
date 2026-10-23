#!/bin/zsh
# Builds Whisper.app and installs it into /Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Whisper"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

swift build -c release --arch arm64

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift scripts/make_icon.swift "$BUILD_DIR/icon_1024.png"
  for px in 16 32 128 256 512; do
    sips -z $px $px "$BUILD_DIR/icon_1024.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$BUILD_DIR/icon_1024.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/WhisperApp "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# A stable certificate keeps macOS Microphone/Accessibility grants across rebuilds;
# ad-hoc signatures change every build and macOS resets the permissions.
SIGNING_IDENTITY="Whisper Local Signing"
security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1 || SIGNING_IDENTITY="-"
codesign --force --sign "$SIGNING_IDENTITY" --identifier com.samirgiripunje.whisper "$APP"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x WhisperApp 2>/dev/null && sleep 0.5 || true
  rm -rf "$INSTALL_PATH"
  cp -R "$APP" "$INSTALL_PATH"
  echo "Installed $INSTALL_PATH"
fi
