#!/bin/sh
# Installs Agent Away:
#   1. builds the app into ~/Library/Application Support/AgentAway
#   2. adds its hooks to ~/.claude/settings.json (backed up first; other hooks untouched)
#   3. adds a login item (LaunchAgent) and starts it
# Re-running is safe: it replaces its own entries. Undo with uninstall.sh.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HOME/Library/Application Support/AgentAway"
APP="$DEST/AgentAway.app"
HOOK="$DEST/away-hook.sh"
SETTINGS="$HOME/.claude/settings.json"
LABEL=local.agentaway
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

sh "$HERE/scripts/build.sh"

# --- hooks -------------------------------------------------------------------
mkdir -p "$DEST/backups" "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$DEST/backups/settings.json.$(date +%Y%m%d-%H%M%S)"
ls -t "$DEST/backups"/settings.json.* 2>/dev/null | tail -n +4 | while read -r f; do rm -f "$f"; done

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
/usr/bin/jq --arg cmd "/bin/sh \"$HOOK\"" -f "$HERE/scripts/hooks.jq" "$SETTINGS" > "$TMP"
/usr/bin/jq -e . "$TMP" >/dev/null # never write broken JSON
cat "$TMP" > "$SETTINGS"           # keep the file's inode and permissions
echo "Hooks added to $SETTINGS (backup in $DEST/backups)"

# --- login item --------------------------------------------------------------
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AgentAway</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Login item installed and started ($LABEL)."

if [ ! -f /etc/sudoers.d/agent-away ]; then
    echo
    echo "One step left for lid-closed mode (asks for your password once):"
    echo "  sh \"$HERE/scripts/setup-sudo.sh\""
fi
