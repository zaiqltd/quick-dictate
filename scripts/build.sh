#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/build/Quick Dictate.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swift scripts/icon.swift "$PWD/build/AppIcon.iconset"
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
xcrun swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" Sources/*.swift -o "$APP/Contents/MacOS/QuickDictate"
cp Info.plist "$APP/Contents/Info.plist"
if [[ -f build/AppIcon.icns ]]; then cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - --identifier local.chad.quick-dictate --requirements '=designated => identifier "local.chad.quick-dictate"' "$APP"
codesign --verify --deep --strict "$APP"
print "Built: $APP"
