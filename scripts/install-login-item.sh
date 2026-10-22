#!/bin/sh
# Starts Orbit at login through a per-user LaunchAgent that opens build/Orbit.app.
# Rebuilding keeps the same path, so the agent picks up new builds. Run with --remove to uninstall.
set -e
cd "$(dirname "$0")/.."
LABEL=dev.kielblock.orbit
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$(pwd)/build/Orbit.app"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true

if [ "$1" = "--remove" ]; then
    rm -f "$PLIST"
    echo "Removed $PLIST"
    exit 0
fi

[ -d "$APP" ] || ./scripts/build-app.sh
mkdir -p "$HOME/Library/LaunchAgents"
# `open` goes through LaunchServices, so an already running copy is reused instead of started twice.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed $PLIST"
