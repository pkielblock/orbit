#!/bin/sh
# Run from the private staging directory after the parent app exits.
set -u
PARENT_PID=$1
APP=$2
STAGING=$3
BACKUP="$STAGING/previous.app"

audit() {
    echo "{\"timestamp\":\"$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event_id\":\"$(/usr/bin/uuidgen)\",\"event_type\":\"app.update.install\",\"severity\":\"INFO\",\"actor\":{\"id\":\"local-user\",\"type\":\"user\"},\"action\":{\"type\":\"UPDATE\",\"outcome\":\"$1\"},\"resource\":{\"id\":\"dev.kielblock.orbit\",\"type\":\"application\"},\"context\":{\"service\":\"orbit\",\"environment\":\"desktop\"}}"
}

# Bound the wait: if termination was cancelled, leave the running app untouched.
ATTEMPTS=0
while /bin/kill -0 "$PARENT_PID" 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge 60 ]; then
        audit failure
        /bin/rm -rf "$STAGING"
        exit 1
    fi
    /bin/sleep 1
done

if ! /bin/mv "$APP" "$BACKUP"; then
    audit failure
    /usr/bin/open "$APP"
    /bin/rm -rf "$STAGING"
    exit 1
fi
if /bin/mv "$STAGING/Orbit.app" "$APP" && /usr/bin/open "$APP"; then
    audit success
    /bin/rm -rf "$STAGING"
else
    # Keep the previous app recoverable even if restoration itself fails.
    /bin/rm -rf "$APP"
    if /bin/mv "$BACKUP" "$APP"; then
        /usr/bin/open "$APP"
        /bin/rm -rf "$STAGING"
    fi
    audit failure
fi
