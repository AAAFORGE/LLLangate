#!/bin/zsh
# Langate uninstaller — removes launchd jobs and all config.
# Caddy itself (brew package) is left alone.
set -e
GATE_DIR="$HOME/.config/langate"
LA_DIR="$HOME/Library/LaunchAgents"
UID_N=$(id -u)
YES=0
[[ "$1" == "-y" || "$1" == "--yes" ]] && YES=1

echo "This removes Langate: launchd jobs (com.langate.gate/caddy), plists,"
echo "and $GATE_DIR (Caddyfile, token, allowlist, logs, certs)."
if (( ! YES )); then
  read "ANS?Proceed? [y/N] "
  [[ "$ANS" == (y|Y|yes|YES) ]] || { echo "Aborted."; exit 0; }
fi

for label in com.langate.gate com.langate.caddy; do
  launchctl bootout "gui/$UID_N/$label" 2>/dev/null || true
done
rm -f "$LA_DIR/com.langate.caddy.plist" "$LA_DIR/com.langate.gate.plist"
rm -rf "$GATE_DIR"
[[ -L /opt/homebrew/bin/gate ]] && rm -f /opt/homebrew/bin/gate

echo "Langate removed."
echo "Note: caddy's internal CA was self-contained in the removed directory;"
echo "previously installed root.crt profiles on your devices can be deleted there."
