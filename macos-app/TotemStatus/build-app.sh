#!/bin/sh
# Builds TotemStatus.app (release, arm64) next to this script.
set -e
cd "$(dirname "$0")"
python3 scripts/gen-keymap.py ../../config/totem.keymap \
    ../../config/boards/shields/totem/totem-layouts.dtsi Resources/keymap.json
swift build -c release
APP=TotemStatus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/TotemStatus" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/keymap.json "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
echo "Install: cp -R $APP /Applications/ && open /Applications/$APP"
