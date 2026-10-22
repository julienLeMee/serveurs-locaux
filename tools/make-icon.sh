#!/bin/sh
# Régénère Resources/AppIcon.icns à partir de tools/icon.swift.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
EXTRA=""
CLT_SWIFT="$(xcode-select -p)/usr/include/swift"
if [ -f "$CLT_SWIFT/module.modulemap" ] && [ -f "$CLT_SWIFT/bridging.modulemap" ]; then
  : > "$TMP/empty.modulemap"
  printf '{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file", "name": "%s/module.modulemap", "external-contents": "%s/empty.modulemap" } ] }' "$CLT_SWIFT" "$TMP" > "$TMP/overlay.yaml"
  EXTRA="-vfsoverlay $TMP/overlay.yaml -Xcc -ivfsoverlay -Xcc $TMP/overlay.yaml"
fi
# shellcheck disable=SC2086
swiftc $EXTRA tools/icon.swift -o "$TMP/icon"
"$TMP/icon" "$TMP/icon_1024.png"
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/icon_1024.png" Resources/AppIcon.png
rm -rf "$TMP"
echo "Resources/AppIcon.icns"
