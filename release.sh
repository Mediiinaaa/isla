#!/bin/zsh
# Compila Isla para Apple Silicon e Intel y crea dist/Isla.zip para publicar
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
rm -rf dist && mkdir -p dist/Isla.app/Contents/MacOS dist/Isla.app/Contents/Resources
cp AppIcon.icns dist/Isla.app/Contents/Resources/AppIcon.icns
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Isla" dist/Isla.app/Contents/MacOS/Isla
cp Info.plist dist/Isla.app/Contents/Info.plist
codesign --force --sign - dist/Isla.app
ditto -c -k --keepParent dist/Isla.app dist/Isla.zip
echo "Listo: dist/Isla.zip"
