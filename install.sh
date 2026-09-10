#!/bin/zsh
# Langate installer — expose a localhost service to your LAN behind a
# Wi-Fi allowlist + token gate. Never exposes anything to the internet.
#
# Interactive by default; fully scriptable with flags:
#   ./install.sh --upstream 127.0.0.1:3000 --ssid HomeWifi [--ssid OfficeWifi]
#                [--https-port 8443] [--cert-port 8444] [--hostname mymac.local]
#                [--force] [-y]
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE_DIR="$HOME/.config/langate"
LA_DIR="$HOME/Library/LaunchAgents"

PORT_HTTPS=8443
PORT_CERT=8444
HOSTNAME_ARG=""
UPSTREAM=""
typeset -a SSIDS
FORCE=0
QUIET=0

usage() {
  cat <<'EOF'
Langate — gated LAN entry for localhost services.

Usage: ./install.sh [flags]

Flags:
  --upstream host:port   Local service to protect (e.g. 127.0.0.1:3000)
  --hostname name.local  Entry hostname (default: this Mac's Bonjour name)
  --https-port N         HTTPS entry port (default 8443)
  --cert-port N          HTTP port that only serves root.crt (default 8444)
  --ssid NAME            Allow this Wi-Fi (repeatable; prompts if missing)
  --force                Reinstall over an existing config
  -y                     Assume defaults, no confirmation
  -h, --help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream)    UPSTREAM="$2"; shift 2 ;;
    --hostname)    HOSTNAME_ARG="$2"; shift 2 ;;
    --https-port)  PORT_HTTPS="$2"; shift 2 ;;
    --cert-port)   PORT_CERT="$2"; shift 2 ;;
    --ssid)        SSIDS+=("$2"); shift 2 ;;
    --force)       FORCE=1; shift ;;
    -y)            QUIET=1; shift ;;
    -h|--help)     usage ;;
    *) echo "Unknown flag: $1" >&2; usage ;;
  esac
done

info()  { print -P " %F{green}●%f $*"; }
warn()  { print -P " %F{yellow}▲%f $*"; }
fail()  { print -P " %F{red}✗%f $*" >&2; exit 1; }

echo "Langate installer"
echo "─────────────────"

# --- environment checks ---
[[ "$(uname)" == "Darwin" ]] || fail "macOS only."
CADDY_BIN="$(command -v caddy || true)"
[[ -z "$CADDY_BIN" && -x /opt/homebrew/bin/caddy ]] && CADDY_BIN=/opt/homebrew/bin/caddy
[[ -n "$CADDY_BIN" ]] || fail "caddy not found. Install it first:  brew install caddy"
info "caddy: $CADDY_BIN ($($CADDY_BIN version | cut -d' ' -f1))"

if [[ -f "$GATE_DIR/config.env" && $FORCE -eq 0 ]]; then
  fail "Already installed at $GATE_DIR — use --force to reinstall."
fi

# --- gather settings ---
if [[ -z "$HOSTNAME_ARG" ]]; then
  HOSTNAME_ARG="$(scutil --get LocalHostName 2>/dev/null).local"
fi
if [[ -z "$UPSTREAM" && -t 0 ]]; then
  read "UPSTREAM?Upstream service (host:port, e.g. 127.0.0.1:3000): "
fi
[[ -n "$UPSTREAM" ]] || fail "No upstream given. Pass --upstream host:port."
if (( ${#SSIDS} == 0 )) && [[ -t 0 ]]; then
  read "ANS?Allowed Wi-Fi SSIDs (space or comma separated): "
  for s in ${(f)"$(print -r -- "$ANS" | tr ', ' '\n')"}; do
    [[ -n "$s" ]] && SSIDS+=("$s")
  done
fi
(( ${#SSIDS} > 0 )) || fail "No SSID given. Pass --ssid NAME (or run interactively)."

# --- validate ---
if ! curl -s -o /dev/null --max-time 3 "http://$UPSTREAM"; then
  fail "Upstream http://$UPSTREAM is not reachable. Start the service first."
fi
info "upstream http://$UPSTREAM reachable"

port_in_use() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
for p in $PORT_HTTPS $PORT_CERT; do
  # our own leftover caddy doesn't count as a conflict on --force
  if port_in_use "$p" && ! pgrep -f "caddy run --config $GATE_DIR/Caddyfile" >/dev/null; then
    fail "Port $p is already in use by another program. Pick another with --https-port/--cert-port."
  fi
done
info "ports $PORT_HTTPS (https) / $PORT_CERT (cert) free"

TOKEN="$(openssl rand -hex 16)"
CADDY_STORAGE="$GATE_DIR/caddy-storage"

# --- render files ---
mkdir -p "$GATE_DIR" "$CADDY_STORAGE" "$LA_DIR"
render() {
  sed -e "s|__GATE_DIR__|$GATE_DIR|g" \
      -e "s|__CADDY_STORAGE__|$CADDY_STORAGE|g" \
      -e "s|__CADDY_BIN__|$CADDY_BIN|g" \
      -e "s|__HOSTNAME__|$HOSTNAME_ARG|g" \
      -e "s|__PORT_HTTPS__|$PORT_HTTPS|g" \
      -e "s|__PORT_CERT__|$PORT_CERT|g" \
      -e "s|__UPSTREAM__|$UPSTREAM|g" \
      -e "s|__TOKEN__|$TOKEN|g" \
      "$1" > "$2"
}

render "$REPO_DIR/templates/Caddyfile.tmpl"            "$GATE_DIR/Caddyfile"
render "$REPO_DIR/templates/gate-tick.sh.tmpl"          "$GATE_DIR/gate-tick.sh"
render "$REPO_DIR/templates/com.langate.caddy.plist.tmpl" "$LA_DIR/com.langate.caddy.plist"
render "$REPO_DIR/templates/com.langate.gate.plist.tmpl"  "$LA_DIR/com.langate.gate.plist"
chmod +x "$GATE_DIR/gate-tick.sh"

printf '%s\n' "${SSIDS[@]}" > "$GATE_DIR/allowed-ssids.txt"

cat > "$GATE_DIR/config.env" <<EOF
PORT_HTTPS=$PORT_HTTPS
PORT_CERT=$PORT_CERT
HOSTNAME=$HOSTNAME_ARG
UPSTREAM=$UPSTREAM
TOKEN=$TOKEN
CADDY_BIN=$CADDY_BIN
GATE_DIR=$GATE_DIR
EOF
chmod 600 "$GATE_DIR/config.env"

# CLI: make `gate` available if we can
GATE_CLI="$GATE_DIR/gate"
cp "$REPO_DIR/bin/gate" "$GATE_CLI"
chmod +x "$GATE_CLI"
if [[ -w /opt/homebrew/bin && ! -e /opt/homebrew/bin/gate ]]; then
  ln -sf "$GATE_CLI" /opt/homebrew/bin/gate && info "'gate' linked into /opt/homebrew/bin"
elif ! command -v gate >/dev/null 2>&1; then
  warn "add to PATH:  export PATH=\"$GATE_DIR:\$PATH\"  (or: alias gate=\"$GATE_CLI\")"
fi

# --- start (bootstrap gate agent; its first tick starts caddy if allowed) ---
UID_N=$(id -u)
launchctl bootout "gui/$UID_N/com.langate.gate" 2>/dev/null || true
launchctl bootout "gui/$UID_N/com.langate.caddy" 2>/dev/null || true
launchctl bootstrap "gui/$UID_N" "$LA_DIR/com.langate.gate.plist" \
  || fail "launchctl bootstrap failed — see ~/Library/Logs or gate.log"
sleep 3

if port_in_use "$PORT_HTTPS"; then
  info "entry is UP on port $PORT_HTTPS"
else
  warn "entry not up yet — current Wi-Fi may not be in the allowlist; it will open automatically when you join an allowed network"
fi

echo ""
echo "─────────────────"
echo " Langate is installed."
echo ""
echo "   Entry:      https://$HOSTNAME_ARG:$PORT_HTTPS"
echo "   Gate link:  https://$HOSTNAME_ARG:$PORT_HTTPS/gate?t=$TOKEN"
echo "   Root cert:  http://$HOSTNAME_ARG:$PORT_CERT/root.crt"
echo ""
echo " On iPhone/iPad (once per device):"
echo "   1. open the root.crt URL → install profile → enable Full Trust"
echo "      (Settings → General → About → Certificate Trust Settings)"
echo "   2. open the gate link → cookie is set → service loads"
echo "   3. Share → Add to Home Screen"
echo ""
echo " Manage:  gate status | allow | deny | token | rotate-token | doctor | stop | start"
echo " Config:  $GATE_DIR   (allowlist: allowed-ssids.txt)"
echo "─────────────────"
