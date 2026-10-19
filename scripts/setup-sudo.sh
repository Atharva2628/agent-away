#!/bin/sh
# One-time setup (run it yourself; it asks for your password once).
# Lets Agent Away keep the Mac awake with the lid closed by allowing exactly
# two commands without a password, for your user only:
#   /usr/bin/pmset -a disablesleep 1     (lid-closed awake on)
#   /usr/bin/pmset -a disablesleep 0     (back to normal)
# Nothing else is allowed. Remove with:  sh setup-sudo.sh --remove
set -eu

F=/etc/sudoers.d/agent-away
U=$(id -un)

if [ "${1:-}" = "--remove" ]; then
    # Only undo lid-closed awake if Agent Away turned it on (never a setting of yours).
    if [ -f "$HOME/Library/Application Support/AgentAway/sleep-disabled-by-agent-away" ]; then
        sudo /usr/bin/pmset -a disablesleep 0
    fi
    sudo rm -f "$F"
    echo "Removed $F."
    exit 0
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' "$U" > "$TMP"
/usr/sbin/visudo -cf "$TMP" >/dev/null
sudo /usr/bin/install -m 0440 -o root -g wheel "$TMP" "$F"
if ! sudo /usr/sbin/visudo -c >/dev/null; then
    sudo rm -f "$F"
    echo "sudoers check failed; nothing changed." >&2
    exit 1
fi
echo "Installed $F:"
sudo cat "$F"
