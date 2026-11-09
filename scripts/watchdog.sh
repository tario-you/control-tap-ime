#!/bin/bash
# Run by launchd every 30 seconds. If the helper does not answer, restart it (or load its
# LaunchAgent if it was unloaded) so Control taps recover without anyone noticing.
set -u
LABEL=io.github.tario-you.controltap-ime
BINARY=/Applications/ControlTapIME.app/Contents/MacOS/controltap-ime
DOMAIN="gui/$(id -u)"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/ControlTapIME"
LOG="$SUPPORT/watchdog.log"

answers() { "$BINARY" status >/dev/null 2>&1; }
note() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

answers && exit 0
# A helper that is starting or was just restarted by launchd gets ten seconds first.
for _ in 1 2 3 4 5; do sleep 2; answers && exit 0; done

if [ ! -x "$BINARY" ]; then note "app missing at $BINARY; cannot restart"; exit 1; fi
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "$DOMAIN/$LABEL"; action=restarted
else
    launchctl bootstrap "$DOMAIN" "$AGENT"; action=reloaded
fi
for _ in $(seq 1 20); do answers && { note "$action helper: answering"; exit 0; }; sleep 1; done
note "$action helper: still not answering; see error.log"
exit 1
