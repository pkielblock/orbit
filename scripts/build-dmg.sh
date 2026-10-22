#!/bin/sh
# Rebuilds Orbit.app and packs it into a drag-to-install disk image next to an Applications link.
# The image is named after CFBundleShortVersionString in Resources/Info.plist.
set -e
cd "$(dirname "$0")/.."
./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/Orbit-$VERSION.dmg"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# Ad-hoc signature seals the bundle so it launches on Apple silicon after being copied out of the image.
codesign --force --sign - build/Orbit.app
cp -R build/Orbit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# `diskutil image` replaces hdiutil on newer macOS; CI runners on older releases still need hdiutil.
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format ULFO --volumeName "Orbit $VERSION" "$STAGE" "$DMG" >/dev/null
else
    hdiutil create -volname "Orbit $VERSION" -srcfolder "$STAGE" -format ULFO -ov "$DMG" >/dev/null
fi
rm -rf "$STAGE"
echo "Built $DMG"
if [ "${1:-}" = "--open" ]; then
    # Mount directly and request Finder's drag-to-Applications window.
    hdiutil attach -readonly -autoopen "$DMG"
fi
