#!/bin/sh
# Builds TotemStatus.app (release, arm64) next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=TotemStatus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/TotemStatus" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
echo "Install: cp -R $APP /Applications/ && open /Applications/$APP"
