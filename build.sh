#!/bin/zsh
# Compila Isla, crea build/Isla.app y la instala en /Applications
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
rm -rf build/Isla.app
mkdir -p build/Isla.app/Contents/MacOS build/Isla.app/Contents/Resources
cp AppIcon.icns build/Isla.app/Contents/Resources/AppIcon.icns
cp .build/release/Isla build/Isla.app/Contents/MacOS/Isla
cp Info.plist build/Isla.app/Contents/Info.plist
codesign --force --sign - build/Isla.app
pkill -x Isla || true
rm -rf /Applications/Isla.app
cp -R build/Isla.app /Applications/Isla.app
echo "Listo: /Applications/Isla.app"
