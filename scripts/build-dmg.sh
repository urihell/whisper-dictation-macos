#!/bin/bash
#
# Builds a Release WhisperDictation.app and packages it into a drag-to-install
# DMG. Signed ad-hoc (no Apple Developer ID / notarization), so on other Macs
# the recipient must clear quarantine once — see README / the printed note.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="WhisperDictation"
VOL_NAME="Whisper Dictation"
DERIVED="build_release"
DIST="dist"

echo "▸ Regenerating Xcode project…"
xcodegen generate >/dev/null

echo "▸ Building Release (ad-hoc signed, hardened runtime off for portability)…"
xcodebuild -scheme "$APP_NAME" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO \
  build >/dev/null

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "✗ build failed — $APP not found"; exit 1; }

echo "▸ Verifying signature…"
codesign --verify --deep --strict "$APP" && echo "  signature OK (ad-hoc)"

echo "▸ Assembling DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$DIST"
DMG="$DIST/$APP_NAME.dmg"
rm -f "$DMG"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "▸ Done → $DMG ($(du -h "$DMG" | cut -f1))"
echo
echo "On another Mac: open the DMG, drag the app to Applications, then first launch"
echo "is blocked by Gatekeeper — approve via System Settings → Privacy & Security →"
echo "\"Open Anyway\", or run:  xattr -cr \"/Applications/$APP_NAME.app\""
