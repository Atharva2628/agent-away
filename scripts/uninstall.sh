#!/bin/sh
# Removes everything install.sh added: login item, hooks in
# ~/.claude/settings.json (other hooks untouched), the built app and its state.
# Settings backups stay in ~/Library/Application Support/AgentAway/backups.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HOME/Library/Application Support/AgentAway"
SETTINGS="$HOME/.claude/settings.json"
LABEL=local.agentaway
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Stopping the app restores normal sleep (it reverts on quit).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
if [ -f "$DEST/sleep-disabled-by-agent-away" ]; then
    /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || true
fi

if [ -f "$SETTINGS" ]; then
    mkdir -p "$DEST/backups"
    cp "$SETTINGS" "$DEST/backups/settings.json.$(date +%Y%m%d-%H%M%S)"
    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT
    /usr/bin/jq --arg cmd "" --arg remove 1 -f "$HERE/scripts/hooks.jq" "$SETTINGS" > "$TMP"
    /usr/bin/jq -e . "$TMP" >/dev/null
    cat "$TMP" > "$SETTINGS"
    echo "Removed Agent Away hooks from $SETTINGS"
fi

rm -rf "$DEST/AgentAway.app" "$DEST/away-hook.sh" "$DEST/run" "$DEST/sleep-disabled-by-agent-away"
defaults delete local.agentaway 2>/dev/null || true
echo "Uninstalled. Backups kept in: $DEST/backups"
if [ -f /etc/sudoers.d/agent-away ]; then
    echo "To also remove the lid-closed sudo rule:  sh \"$HERE/scripts/setup-sudo.sh\" --remove"
fi
