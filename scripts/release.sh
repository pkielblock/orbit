#!/bin/sh
# Tests, builds the disk image on this Mac and publishes it as a GitHub release: v<version>.<next number>, with notes
# listing the commits since the previous release. Publish from a clean main that is already pushed.
set -e
cd "$(dirname "$0")/.."

[ "$(git branch --show-current)" = main ] || { echo "Release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first" >&2; exit 1; }
git fetch --quiet --tags origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main and origin/main differ; sync them first" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
LAST=$(git tag --list "v$VERSION.*" | sed "s/^v$VERSION\.//" | sort -n | tail -1)
TAG="v$VERSION.$((${LAST:-0} + 1))"

swift test
ORBIT_RELEASE_VERSION="${TAG#v}" ./scripts/build-dmg.sh

NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT
PREV=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
{
    echo "## Changes"
    git log --no-merges --format='- %s (%h)' ${PREV:+$PREV..}HEAD
} > "$NOTES"
gh release create "$TAG" "build/Orbit-$VERSION.dmg" \
    --target "$(git rev-parse HEAD)" --title "Orbit $TAG" --notes-file "$NOTES" --latest
echo "Published $TAG"
