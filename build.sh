#!/bin/sh
# Compile « Serveurs locaux.app » et l'installe dans ~/Applications.
#   ./build.sh            compiler, installer, lancer
#   ./build.sh --no-open  compiler et installer seulement
# Requiert les outils de développement Apple : xcode-select --install
set -e
cd "$(dirname "$0")"

NAME="Serveurs locaux"
EXE="ServeursLocaux"
APP="build/$NAME.app"
DEST="$HOME/Applications/$NAME.app"
MIN_MACOS=14.0

command -v swiftc >/dev/null || { echo "Installez d'abord les outils Apple : xcode-select --install"; exit 1; }

# Certaines installations des Command Line Tools livrent deux module maps
# SwiftBridging, ce qui casse « import SwiftUI ». On masque le doublon le temps
# de la compilation (overlay virtuel, rien n'est modifié sur le disque).
EXTRA=""
CLT_SWIFT="$(xcode-select -p)/usr/include/swift"
if [ -f "$CLT_SWIFT/module.modulemap" ] && [ -f "$CLT_SWIFT/bridging.modulemap" ]; then
  mkdir -p build
  : > build/empty.modulemap
  cat > build/overlay.yaml <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file", "name": "$CLT_SWIFT/module.modulemap", "external-contents": "$PWD/build/empty.modulemap" } ] }
YAML
  EXTRA="-vfsoverlay $PWD/build/overlay.yaml -Xcc -ivfsoverlay -Xcc $PWD/build/overlay.yaml"
fi

echo "Compilation…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for ARCH in arm64 x86_64; do
  # shellcheck disable=SC2086
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos$MIN_MACOS" $EXTRA \
    Sources/*.swift -o "build/$EXE-$ARCH"
done
lipo -create "build/$EXE-arm64" "build/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"
rm -f "build/$EXE-arm64" "build/$EXE-x86_64"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.serveurs-locaux</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
</dict></plist>
PLIST
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

# Remplace la version installée (l'app elle-même, pas vos serveurs).
pkill -x "$EXE" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mv "$APP" "$DEST"  # déplacée, pas copiée : une seule app pour Spotlight
echo "Installé : $DEST"

[ "$1" = "--no-open" ] || open "$DEST"
