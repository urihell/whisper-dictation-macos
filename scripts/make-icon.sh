#!/bin/bash
#
# Generates the AppIcon asset (all macOS sizes) from a rendered 1024px master.
#
set -euo pipefail
cd "$(dirname "$0")/.."

SET="WhisperDictation/Resources/Assets.xcassets/AppIcon.appiconset"
CATALOG="WhisperDictation/Resources/Assets.xcassets"
TMP="$(mktemp -d)"

echo "▸ Rendering 1024px master…"
swift scripts/MakeIcon.swift "$TMP/icon_1024.png"

echo "▸ Generating sizes…"
mkdir -p "$SET"
for px in 16 32 64 128 256 512 1024; do
  sips -z "$px" "$px" "$TMP/icon_1024.png" --out "$SET/icon_${px}.png" >/dev/null
done
rm -rf "$TMP"

echo "▸ Writing Contents.json…"
cat > "$CATALOG/Contents.json" <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON

cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16",   "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16",   "scale" : "2x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "2x", "filename" : "icon_64.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "▸ Done. AppIcon set at $SET"
ls "$SET"
