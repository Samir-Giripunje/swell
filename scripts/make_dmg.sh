#!/bin/zsh
# Packages build/Wisper.app into a drag-to-Applications DMG plus a SHA-256 checksum.
# Usage: VERSION=1.0.0 scripts/make_dmg.sh   (needs `brew install create-dmg`)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:?set VERSION, e.g. VERSION=1.0.0}"
APP="build/Wisper.app"
STAGING="build/dmg"
DMG="build/Wisper-$VERSION.dmg"

[[ -d "$APP" ]] || { echo "Missing $APP — run ./build.sh --no-install first"; exit 1; }

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"

create-dmg \
  --volname "Wisper $VERSION" \
  --volicon Resources/AppIcon.icns \
  --background Resources/dmg-background.tiff \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "Wisper.app" 180 190 \
  --hide-extension "Wisper.app" \
  --app-drop-link 480 190 \
  --no-internet-enable \
  "$DMG" "$STAGING"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-Whisper Local Signing}"
if security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$SIGNING_IDENTITY" --identifier com.samirgiripunje.whisper.dmg "$DMG"
fi

(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
rm -rf "$STAGING"
echo "Created $DMG"
