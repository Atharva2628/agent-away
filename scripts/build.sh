#!/bin/sh
# Compiles Agent Away into ~/Library/Application Support/AgentAway (kept out of
# the iCloud-synced Desktop so the binary is never evicted) and copies the hook.
# All compiler caches go to a temp dir that is deleted afterwards.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HOME/Library/Application Support/AgentAway"
APP="$DEST/AgentAway.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

/usr/bin/swiftc -O -swift-version 5 -module-cache-path "$TMP/mc" \
    -o "$TMP/AgentAway" "$HERE"/src/*.swift

mkdir -p "$APP/Contents/MacOS"
cp "$TMP/AgentAway" "$APP/Contents/MacOS/AgentAway"
cp "$HERE/src/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/codesign --force -s - "$APP" >/dev/null 2>&1
install -m 0755 "$HERE/hooks/away-hook.sh" "$DEST/away-hook.sh"
printf '%s\n' "$HERE" > "$DEST/source-dir"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
