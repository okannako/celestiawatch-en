#!/usr/bin/env bash
# =====================================================================
#  celestiawatch - Celestia Validator + Fibre health check and Telegram alert tool
#  https://github.com/okannako
#
#  SECURITY PRINCIPLES
#   - READ-ONLY. Never changes node config, never stops/starts services.
#   - Never sends transactions, never runs wallet/key commands.
#   - Opens no ports. Only reads the 127.0.0.1 RPC and sends messages to Telegram.
#   - The alert service does NOT run as root but as a separate unprivileged
#     "celestiawatch" user that cannot see /root or /home (no access to your keys).
#
#  COMMANDS
#   sudo ./celestiawatcheng.sh install     Install (asks a few questions, sets up service + timer)
#   sudo celestiawatch uninstall        Remove everything
#   sudo celestiawatch doctor           Detailed one-time health report (terminal)
#   celestiawatch status                Current status summary (terminal)
#   sudo celestiawatch test             Send a test message to Telegram
#   celestiawatch watch                 The check the service runs every minute
# =====================================================================
set -u
VERSION="1.0.0"
CONFIG_FILE="${CELESTIAWATCH_CONFIG:-/etc/celestiawatch/config.env}"
STATE_DIR="${STATE_DIRECTORY:-/var/lib/celestiawatch}"

# ---------- Defaults (overridden by config.env) ----------
RPC="http://127.0.0.1:26657"
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""
NODE_LABEL="validator"          # Name shown in messages. Do not use your IP or city.
APP_SERVICE="celestia-appd"
FIBRE_SERVICE="fibre"           # Leave empty if you don't run Fibre: FIBRE_SERVICE=""
BRIDGE_SERVICE=""               # If you run a bridge: BRIDGE_SERVICE="celestia-bridge"
FIBRE_PORT=7980
DISK_PATHS="/"                  # Multiple: DISK_PATHS="/ /data"
DISK_ALERT_PERCENT=85
MIN_PEERS=3
MISSED_ALERT=5                  # Alert if this many blocks are missed in one check
STALL_MINUTES=3                 # Alert if block height doesn't move for this many minutes
REMIND_MINUTES=60               # Remind about ongoing problems at this interval
DAILY_REPORT_HOUR=""            # e.g. 9 -> a status summary every day after 09:00
MAX_BLOCKS_PER_RUN=50
DRY_RUN=0                       # If 1, prints messages instead of sending them

if [ -r "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

SENSITIVE_PORTS="9090 26669 26657 26658 1317"

# ---------- Helpers ----------
need() { command -v "$1" >/dev/null 2>&1; }
rpc() { curl -s --max-time 5 "$RPC/$1" 2>/dev/null; }
now() { date +%s; }

send_tg() {
  local text="[$NODE_LABEL] $1"
  if [ "$DRY_RUN" = "1" ] || [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  # URL is passed to curl via stdin so the token never shows up in the process list.
  local code
  code=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_TOKEN" |
    curl -s --max-time 10 -o /dev/null -w '%{http_code}' -K - \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$text" \
      --data-urlencode "disable_web_page_preview=true")
  if [ "$code" != "200" ]; then
    case "$code" in
      000) echo "Could not reach Telegram (internet/DNS problem)." >&2 ;;
      401|404) echo "Telegram HTTP $code: wrong bot token." >&2 ;;
      400|403) echo "Telegram HTTP $code: wrong Chat ID, or you haven't sent /start to the bot yet." >&2 ;;
      *) echo "Telegram HTTP $code: message could not be sent." >&2 ;;
    esac
    return 1
  fi
}

service_exists() { [ -n "$1" ] && systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q .; }
# Finds the first enabled or running service whose name contains the given word
find_service() {
  local u
  for u in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -i "$1" | sed 's/\.service$//'); do
    if systemctl is-enabled --quiet "$u" 2>/dev/null || systemctl is-active --quiet "$u" 2>/dev/null; then echo "$u"; return; fi
  done
}
service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# Is any sensitive port listening on something other than 127.0.0.1?
exposed_ports() {
  need ss || return 0
  ss -Hltn 2>/dev/null | awk '{print $4}' | while read -r a; do
    local port="${a##*:}" host="${a%:*}"
    case " $SENSITIVE_PORTS " in *" $port "*) ;; *) continue ;; esac
    case "$host" in 127.*|"[::1]"|"[::ffff:127."*|localhost) continue ;; esac
    echo "$port"
  done | sort -u | tr '\n' ' ' | sed 's/ $//'
}

port_listening() { need ss && ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

disk_usage() { df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'; }

# ---------- Shared data collection ----------
collect() {
  STATUS_JSON=$(rpc status)
  RPC_OK=0; HEIGHT=""; CATCHING=""; NETWORK=""; VAL_ADDR=""; VP=""; PEERS=""; APPV=""
  if [ -n "$STATUS_JSON" ] && echo "$STATUS_JSON" | jq -e .result >/dev/null 2>&1; then
    RPC_OK=1
    HEIGHT=$(echo "$STATUS_JSON" | jq -r .result.sync_info.latest_block_height)
    CATCHING=$(echo "$STATUS_JSON" | jq -r .result.sync_info.catching_up)
    NETWORK=$(echo "$STATUS_JSON" | jq -r .result.node_info.network)
    VAL_ADDR=$(echo "$STATUS_JSON" | jq -r .result.validator_info.address)
    VP=$(echo "$STATUS_JSON" | jq -r .result.validator_info.voting_power)
    PEERS=$(rpc net_info | jq -r '.result.n_peers // empty' 2>/dev/null)
    APPV=$(rpc abci_info | jq -r '.result.response.app_version // empty' 2>/dev/null)
  fi
}

# How many blocks were missed since the last checked block (read-only, RPC /commit)
count_missed() {
  MISSED=0; CHECKED=0
  [ "$RPC_OK" = 1 ] && [ "${VP:-0}" != "0" ] || return 0
  local last start end h n
  last=$(cat "$STATE_DIR/last_height" 2>/dev/null || echo 0)
  end=$((HEIGHT - 1))
  start=$((last + 1))
  [ $((end - start + 1)) -gt "$MAX_BLOCKS_PER_RUN" ] && start=$((end - MAX_BLOCKS_PER_RUN + 1))
  for ((h = start; h <= end; h++)); do
    n=$(rpc "commit?height=$h" | jq -r --arg a "$VAL_ADDR" \
      '[.result.signed_header.commit.signatures[]? | select(.validator_address==$a and (.block_id_flag==2 or .block_id_flag==3))] | length' 2>/dev/null)
    [ -z "$n" ] && continue
    CHECKED=$((CHECKED + 1))
    [ "$n" = "0" ] && MISSED=$((MISSED + 1))
  done
  [ "$end" -gt 0 ] && echo "$end" > "$STATE_DIR/last_height"
}

summary_text() {
  local s="📊 Status"$'\n'
  if [ "$RPC_OK" = 1 ]; then
    local sync="yes"; [ "$CATCHING" = "true" ] && sync="NO (catching up)"
    local set="in active set"; [ "${VP:-0}" = "0" ] && set="NOT in active set"
    s+="Network: $NETWORK | Block: $HEIGHT | Synced: $sync"$'\n'
    s+="Peers: ${PEERS:-?} | Voting power: ${VP:-?} ($set) | app v${APPV:-?}"$'\n'
  else
    s+="RPC not responding ($RPC)"$'\n'
  fi
  for svc in "$APP_SERVICE" "$FIBRE_SERVICE" "$BRIDGE_SERVICE"; do
    service_exists "$svc" || continue
    if service_active "$svc"; then s+="$svc: running"; else s+="$svc: NOT RUNNING"; fi
    if [ "$svc" = "$FIBRE_SERVICE" ]; then
      if port_listening "$FIBRE_PORT"; then s+=" (listening on $FIBRE_PORT)"; else s+=" (NOT listening on $FIBRE_PORT)"; fi
    fi
    s+=$'\n'
  done
  for p in $DISK_PATHS; do s+="Disk $p: $(disk_usage "$p")%"$'\n'; done
  local ex; ex=$(exposed_ports)
  if [ -n "$ex" ]; then s+="⚠️ Sensitive port exposed: $ex"$'\n'; else s+="Sensitive ports: closed (127.0.0.1 only)"$'\n'; fi
  printf '%s' "$s"
}

# ---------- watch: run by the service every minute ----------
cmd_watch() {
  if [ "$(id -u)" = "0" ] && [ "${CELESTIAWATCH_ALLOW_ROOT:-0}" != "1" ]; then
    echo "watch is run by the service as the celestiawatch user. To check manually: celestiawatch status"
    exit 1
  fi
  mkdir -p "$STATE_DIR" || exit 1
  exec 9>"$STATE_DIR/lock"; flock -n 9 || exit 0

  declare -A NOW=() PREV=()
  issue() { NOW["$1"]="$2"; }

  if [ -f "$STATE_DIR/alerts" ]; then
    while IFS='|' read -r k m; do [ -n "$k" ] && PREV["$k"]="$m"; done < "$STATE_DIR/alerts"
  fi

  collect

  if [ "$RPC_OK" != 1 ]; then
    issue rpc "Node RPC not responding. Is celestia-appd running?"
    # Without RPC chain checks are impossible; don't report earlier problems as "resolved".
    for k in sync stall peers inactive missed; do
      [ -n "${PREV[$k]+x}" ] && issue "$k" "${PREV[$k]}"
    done
  else
    [ "$CATCHING" = "true" ] && issue sync "Node is not synced (catching_up: true). Block: $HEIGHT"

    # Is the chain moving?
    local lh lt
    read -r lh lt 2>/dev/null < "$STATE_DIR/height_seen" || { lh=0; lt=$(now); }
    if [ "$HEIGHT" != "$lh" ]; then
      echo "$HEIGHT $(now)" > "$STATE_DIR/height_seen"
    elif [ $(( $(now) - lt )) -ge $((STALL_MINUTES * 60)) ]; then
      issue stall "Block height has not moved for $STALL_MINUTES minutes (block $HEIGHT)."
    fi

    [ -n "$PEERS" ] && [ "$PEERS" -lt "$MIN_PEERS" ] && issue peers "Low peer count: $PEERS"

    # Dropped out of the active set (jail or unbond)
    local was_active; was_active=$(cat "$STATE_DIR/was_active" 2>/dev/null || echo "")
    if [ "${VP:-0}" = "0" ]; then
      [ "$was_active" = "1" ] && issue inactive "Validator DROPPED out of the active set (voting power 0). It may be jailed."
      [ "$was_active" = "1" ] || echo 0 > "$STATE_DIR/was_active"
    else
      echo 1 > "$STATE_DIR/was_active"
    fi

    count_missed
    if [ "$MISSED" -ge "$MISSED_ALERT" ]; then
      issue missed "Missed $MISSED of the last $CHECKED blocks checked."
    elif [ "$MISSED" -gt 0 ] && [ -f "$STATE_DIR/alerts" ] && grep -q '^missed|' "$STATE_DIR/alerts"; then
      issue missed "$(grep '^missed|' "$STATE_DIR/alerts" | cut -d'|' -f2-)"
    fi
  fi

  for svc in "$APP_SERVICE" "$FIBRE_SERVICE" "$BRIDGE_SERVICE"; do
    service_exists "$svc" || continue
    service_active "$svc" || issue "svc_$svc" "$svc service is not running."
  done
  if service_exists "$FIBRE_SERVICE" && service_active "$FIBRE_SERVICE" && ! port_listening "$FIBRE_PORT"; then
    issue fibre_port "Fibre is running but not listening on port $FIBRE_PORT."
  fi

  local ex; ex=$(exposed_ports)
  [ -n "$ex" ] && issue exposed "Sensitive port(s) exposed to the internet: $ex. These must listen on 127.0.0.1 only."

  local i=0
  for p in $DISK_PATHS; do
    i=$((i + 1))
    local u; u=$(disk_usage "$p")
    [ -n "$u" ] && [ "$u" -ge "$DISK_ALERT_PERCENT" ] && issue "disk$i" "Disk $p is $u% full."
  done

  if need timedatectl; then
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "no" ] && issue ntp "Server clock is not synced (NTP)."
  fi

  # --- Report new / resolved problems ---
  local msg="" k
  for k in "${!NOW[@]}"; do [ -z "${PREV[$k]+x}" ] && msg+="🔴 ${NOW[$k]}"$'\n'; done
  for k in "${!PREV[@]}"; do [ -z "${NOW[$k]+x}" ] && msg+="🟢 Resolved: ${PREV[$k]}"$'\n'; done

  local sent_ok=1
  if [ -n "$msg" ]; then
    send_tg "$msg" || sent_ok=0
    [ "$sent_ok" = 1 ] && now > "$STATE_DIR/last_remind"
  elif [ "${#NOW[@]}" -gt 0 ]; then
    local lr; lr=$(cat "$STATE_DIR/last_remind" 2>/dev/null || echo 0)
    if [ $(( $(now) - lr )) -ge $((REMIND_MINUTES * 60)) ]; then
      local r="⏰ Ongoing problems:"$'\n'
      for k in "${!NOW[@]}"; do r+="🔴 ${NOW[$k]}"$'\n'; done
      send_tg "$r" && now > "$STATE_DIR/last_remind"
    fi
  fi
  # If sending failed, don't save state; it will retry on the next check.
  if [ "$sent_ok" = 1 ]; then
    : > "$STATE_DIR/alerts.tmp"
    for k in "${!NOW[@]}"; do printf '%s|%s\n' "$k" "${NOW[$k]//|/ }" >> "$STATE_DIR/alerts.tmp"; done
    mv "$STATE_DIR/alerts.tmp" "$STATE_DIR/alerts"
  fi

  # --- Daily summary ---
  if [ -n "$DAILY_REPORT_HOUR" ] && [ "$(date +%-H)" -ge "$DAILY_REPORT_HOUR" ]; then
    local today; today=$(date +%F)
    if [ "$(cat "$STATE_DIR/last_daily" 2>/dev/null)" != "$today" ]; then
      send_tg "$(summary_text)" && echo "$today" > "$STATE_DIR/last_daily"
    fi
  fi
  return 0
}

# ---------- status: current summary to terminal ----------
cmd_status() { collect; summary_text; }

# ---------- doctor: detailed one-time report ----------
ok()   { printf '  \e[32m✔\e[0m %s\n' "$1"; }
bad()  { printf '  \e[31m✘\e[0m %s\n' "$1"; }
warn() { printf '  \e[33m!\e[0m %s\n' "$1"; }
info() { printf '  - %s\n' "$1"; }

cmd_doctor() {
  echo; echo "celestiawatch doctor v$VERSION  (read-only, changes nothing)"; echo
  collect

  echo "Node"
  if [ "$RPC_OK" = 1 ]; then
    ok "RPC responding ($RPC)"
    info "Network: $NETWORK | Block: $HEIGHT | Peers: ${PEERS:-?}"
    [ "$CATCHING" = "false" ] && ok "Synced" || bad "Not synced (catching_up: $CATCHING)"
    if [ "${APPV:-0}" -ge 10 ] 2>/dev/null; then ok "app_version $APPV (Fibre supported)"; else warn "app_version ${APPV:-?} (Fibre needs 10+)"; fi
    [ "${VP:-0}" != "0" ] && ok "In active set, voting power $VP" || warn "Voting power 0 (not in active set or not a validator)"
  else
    bad "RPC not responding ($RPC)"
  fi

  echo; echo "Services"
  for svc in "$APP_SERVICE" "$FIBRE_SERVICE" "$BRIDGE_SERVICE"; do
    [ -z "$svc" ] && continue
    if ! service_exists "$svc"; then info "$svc: not installed"; continue; fi
    service_active "$svc" && ok "$svc running" || bad "$svc not running"
  done

  echo; echo "Versions"
  local appd_bin; appd_bin=$(command -v celestia-appd || ls /root/go/bin/celestia-appd 2>/dev/null || true)
  local cur=""
  if [ -n "$appd_bin" ]; then cur=$("$appd_bin" version 2>/dev/null | head -1); info "celestia-appd: ${cur:-?}"; else info "celestia-appd not found"; fi
  need fibre && info "fibre: $(fibre version 2>/dev/null | head -1)"
  local latest="" filter='^v[0-9]+\.[0-9]+\.[0-9]+$'
  case "$NETWORK" in mocha*) filter='^v[0-9]+\.[0-9]+\.[0-9]+-mocha$' ;; esac
  latest=$(curl -s --max-time 10 -H "User-Agent: celestiawatch" "https://api.github.com/repos/celestiaorg/celestia-app/releases?per_page=60" |
    jq -r --arg f "$filter" '[.[] | select(.draft==false) | .tag_name | select(test($f))] | sort_by(ltrimstr("v") | split("-")[0] | split(".") | map(tonumber)) | last // empty' 2>/dev/null)
  if [ -n "$latest" ]; then
    if [ "v${cur#v}" = "$latest" ]; then ok "Running the latest release ($latest)"; else warn "Latest release: $latest (you have: ${cur:-?})"; fi
  else
    info "Could not fetch latest release info"
  fi

  if ! service_exists "$FIBRE_SERVICE"; then
    local fs; fs=$(find_service fibre)
    if [ -n "$fs" ]; then
      echo; echo "Fibre"
      warn "Found Fibre service '$fs' but it is not set in the config."
      info "To fix: sudo sed -i 's/^FIBRE_SERVICE=.*/FIBRE_SERVICE=\"$fs\"/' $CONFIG_FILE"
    fi
  fi
  if service_exists "$FIBRE_SERVICE"; then
    echo; echo "Fibre"
    port_listening "$FIBRE_PORT" && ok "Listening on port $FIBRE_PORT" || bad "Not listening on port $FIBRE_PORT"
    if [ -n "$appd_bin" ]; then
      local cons reg host
      cons=$("$appd_bin" comet show-address 2>/dev/null)
      reg=$("$appd_bin" query valaddr provider "$cons" --node "tcp://${RPC#*://}" -o json 2>/dev/null)
      host=$(echo "$reg" | grep -oE '[A-Za-z0-9.-]+:[0-9]+' | head -1)
      if [ -n "$host" ]; then
        ok "Fibre address registered on-chain: $(echo "$host" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+\.[0-9]+/\1.*.*/')"
        local h="${host%:*}" ips resolved
        ips=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
        resolved=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u)
        [ -z "$resolved" ] && resolved="$h"
        if echo "$resolved" | grep -qxF -f <(echo "$ips"); then ok "Registered address points to this server"; else warn "Registered address does not match this server's IPs (may be normal behind NAT or with a domain)"; fi
        [ "${host##*:}" = "$FIBRE_PORT" ] || warn "Registered port is not $FIBRE_PORT: ${host##*:}"
      else
        warn "No Fibre address found on-chain. Did you run 'celestia-appd tx valaddr set-host'?"
      fi
    fi
    info "Test external access from ANOTHER machine: nc -vz SERVER_IP $FIBRE_PORT"
  fi

  echo; echo "Security"
  local ex; ex=$(exposed_ports)
  if ! need ss; then warn "ss command missing, port check skipped (sudo apt install iproute2)"
  elif [ -n "$ex" ]; then bad "Sensitive port exposed: $ex (must listen on 127.0.0.1 only)"; else ok "9090 / 26669 / 26657 / 26658 / 1317 not exposed"; fi
  if need timedatectl; then
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && ok "Clock synced (NTP)" || warn "Clock not synced (NTP)"
  fi
  if need sysctl; then
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] && ok "bbr enabled" || warn "bbr not enabled"
  fi

  echo; echo "Disk"
  for p in $DISK_PATHS; do
    local u; u=$(disk_usage "$p")
    if [ -n "$u" ] && [ "$u" -ge "$DISK_ALERT_PERCENT" ]; then bad "$p $u% full"; else ok "$p ${u:-?}% full"; fi
  done
  echo
}

# ---------- test ----------
cmd_test() {
  collect
  if send_tg "✅ celestiawatch is installed and running."$'\n'"$(summary_text)"; then echo "Test message sent."; else echo "Message could not be sent. Check your token and Chat ID."; exit 1; fi
}

# ---------- install / uninstall ----------
cmd_install() {
  [ "$(id -u)" = "0" ] || { echo "To install: sudo ./celestiawatcheng.sh install"; exit 1; }
  echo "celestiawatch setup. This tool never touches your node config, it only reads."
  local missing=""
  for c in curl jq ss flock systemctl; do need "$c" || missing+=" $c"; done
  if [ -n "$missing" ]; then
    echo "Installing missing packages:$missing"
    apt-get update -qq && apt-get install -y -qq curl jq iproute2 util-linux >/dev/null
  fi

  id celestiawatch >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin celestiawatch
  install -m 755 "$0" /usr/local/bin/celestiawatch
  mkdir -p /etc/celestiawatch

  if [ ! -f /etc/celestiawatch/config.env ]; then
    local tok chat label fib br disks
    echo; echo "Telegram bot token (from @BotFather):"; read -r tok
    echo "Telegram Chat ID (@userinfobot tells you):"; read -r chat
    echo "Name shown in messages (do not use your IP or city) [validator]:"; read -r label
    label=${label:-validator}
    fib=$(find_service fibre)
    br=$(find_service bridge)
    disks="/"; [ -d /data ] && [ "$(df -P /data | awk 'NR==2{print $6}')" != "/" ] && disks="/ /data"
    umask 027
    cat > /etc/celestiawatch/config.env <<EOF
# celestiawatch settings. Changes take effect on the next check, nothing else to do.
TELEGRAM_TOKEN="$tok"
TELEGRAM_CHAT_ID="$chat"
NODE_LABEL="$label"
RPC="http://127.0.0.1:26657"
APP_SERVICE="celestia-appd"
FIBRE_SERVICE="$fib"
BRIDGE_SERVICE="$br"
FIBRE_PORT=7980
DISK_PATHS="$disks"
DISK_ALERT_PERCENT=85
MIN_PEERS=3
MISSED_ALERT=5
STALL_MINUTES=3
REMIND_MINUTES=60
DAILY_REPORT_HOUR=9
EOF
  fi
  chown root:celestiawatch /etc/celestiawatch/config.env
  chmod 640 /etc/celestiawatch/config.env

  cat > /etc/systemd/system/celestiawatch.service <<'EOF'
[Unit]
Description=celestiawatch Celestia validator + Fibre monitoring
After=network-online.target

[Service]
Type=oneshot
User=celestiawatch
Group=celestiawatch
ExecStart=/usr/local/bin/celestiawatch watch
StateDirectory=celestiawatch
TimeoutStartSec=50
Nice=10
MemoryMax=100M
CPUQuota=20%
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
EOF

  cat > /etc/systemd/system/celestiawatch.timer <<'EOF'
[Unit]
Description=celestiawatch check every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now celestiawatch.timer
  echo; /usr/local/bin/celestiawatch test
  echo; echo "Setup complete. For a detailed check: sudo celestiawatch doctor"
  echo "Settings: /etc/celestiawatch/config.env | Logs: journalctl -u celestiawatch"
}

cmd_uninstall() {
  [ "$(id -u)" = "0" ] || { echo "To uninstall: sudo celestiawatch uninstall"; exit 1; }
  systemctl disable --now celestiawatch.timer 2>/dev/null
  rm -f /etc/systemd/system/celestiawatch.service /etc/systemd/system/celestiawatch.timer
  systemctl daemon-reload
  rm -rf /etc/celestiawatch /var/lib/celestiawatch /usr/local/bin/celestiawatch
  id celestiawatch >/dev/null 2>&1 && userdel celestiawatch
  echo "celestiawatch fully removed. Your node was not touched."
}

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  watch)     cmd_watch ;;
  doctor)    cmd_doctor ;;
  status)    cmd_status ;;
  test)      cmd_test ;;
  version)   echo "celestiawatch $VERSION" ;;
  *) echo "Usage: celestiawatch {install|doctor|status|test|uninstall}"; exit 1 ;;
esac
