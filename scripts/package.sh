#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
ZIP="$HOME/Downloads/Quick-Dictate-$VERSION-macOS-universal.zip"
if [[ -e "$ZIP" ]]; then
  print -u2 "Package already exists: $ZIP"
  exit 1
fi

./scripts/build.sh
STAGE=$(mktemp -d "$PWD/build/share.XXXXXX")
RELEASE="$STAGE/Quick Dictate $VERSION"
APP="$RELEASE/Quick Dictate.app"
mkdir -p "$RELEASE"
ditto "build/Quick Dictate.app" "$APP"
cp docs/SHARE-SETUP.txt "$RELEASE/START HERE.txt"

for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" Sources/*.swift -o "$STAGE/QuickDictate-$arch"
done
xcrun lipo -create "$STAGE/QuickDictate-arm64" "$STAGE/QuickDictate-x86_64" -output "$APP/Contents/MacOS/QuickDictate"
xcrun lipo "$APP/Contents/MacOS/QuickDictate" -verify_arch arm64 x86_64
codesign --force --sign - --identifier local.chad.quick-dictate --requirements '=designated => identifier "local.chad.quick-dictate"' "$APP"
codesign --verify --deep --strict "$APP"

python3 - "$APP" <<'PY'
import pathlib, re, sys
app = pathlib.Path(sys.argv[1])
files = [p for p in app.rglob('*') if p.is_file()]
expected = {'Contents/_CodeSignature/CodeResources', 'Contents/MacOS/QuickDictate',
            'Contents/Resources/AppIcon.icns', 'Contents/Info.plist'}
assert {str(p.relative_to(app)) for p in files} == expected, 'Unexpected app-bundle file'
for path in files:
    data = path.read_bytes()
    assert not re.search(rb'sk-or-[A-Za-z0-9_-]{24,}', data), 'API key-like bytes found in app bundle'
    assert (str(pathlib.Path.home()) + '/').encode() not in data, 'Home-folder path found in app bundle'
PY

ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$RELEASE" "$ZIP"
python3 - "$ZIP" "$VERSION" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    root = f'Quick Dictate {sys.argv[2]}/'
    expected = {root + 'START HERE.txt',
                root + 'Quick Dictate.app/Contents/_CodeSignature/CodeResources',
                root + 'Quick Dictate.app/Contents/MacOS/QuickDictate',
                root + 'Quick Dictate.app/Contents/Resources/AppIcon.icns',
                root + 'Quick Dictate.app/Contents/Info.plist'}
    actual = {entry.filename for entry in archive.infolist() if not entry.is_dir()}
    assert actual == expected, 'Archive contains unexpected files'
    assert archive.testzip() is None, 'Archive failed ZIP integrity check'
PY
mkdir -p "$STAGE/unpacked"
ditto -x -k "$ZIP" "$STAGE/unpacked"
codesign --verify --deep --strict "$STAGE/unpacked/Quick Dictate $VERSION/Quick Dictate.app"
xcrun lipo "$STAGE/unpacked/Quick Dictate $VERSION/Quick Dictate.app/Contents/MacOS/QuickDictate" -verify_arch arm64 x86_64
cmp docs/SHARE-SETUP.txt "$STAGE/unpacked/Quick Dictate $VERSION/START HERE.txt"
print "Package: $ZIP"
