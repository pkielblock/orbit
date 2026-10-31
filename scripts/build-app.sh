#!/bin/sh
# Builds Orbit.app, including its app icon, translations and bundled provider logos.
set -e
cd "$(dirname "$0")/.."
OUT=build/Orbit.app
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/logos"
swiftc -o build/icon scripts/icon.swift
build/icon "$OUT/Contents/Resources/AppIcon.icns"
swiftc -O -o "$OUT/Contents/MacOS/Orbit" Sources/Orbit/*.swift
cp Resources/Privacy.txt "$OUT/Contents/Resources/Privacy.txt"
cp -R Localization/*.lproj "$OUT/Contents/Resources/"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp Resources/install-update.sh "$OUT/Contents/Resources/install-update.sh"
if [ -n "${ORBIT_RELEASE_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ORBIT_RELEASE_VERSION" "$OUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ORBIT_RELEASE_VERSION" "$OUT/Contents/Info.plist"
fi
cp Resources/logos/* "$OUT/Contents/Resources/logos/" 2>/dev/null || true
echo "Built $OUT"
