#!/usr/bin/env bash
# Standalone IP selfsteal installer derived from ip-setup.sh and moonsetup.sh.
# Public :443 = Remnawave REALITY; unauthenticated TLS -> nginx loopback :9443.
# Public :80 = nginx HTTP-01 webroot. Requires Debian/Ubuntu, Docker and systemd.
# sudo NODE_IP=1.2.3.4 LE_EMAIL=you@example.com REMNANODE_SECRET_KEY=... bash ip-selfsteal-setup.sh install
set -Eeuo pipefail
umask 022

REMNANODE_DIR="${REMNANODE_DIR:-/opt/remnanode}"
REMNANODE_SERVICE_NAME="${REMNANODE_SERVICE_NAME:-remnanode}"
REMNANODE_IMAGE="${REMNANODE_IMAGE:-remnawave/node:3.1.0}"
COMPOSE_FILE="${COMPOSE_FILE:-$REMNANODE_DIR/docker-compose.yml}"
CERT_DIR="${CERT_DIR:-$REMNANODE_DIR/xray-ssl}"
MANAGE_REMNANODE="${MANAGE_REMNANODE:-1}"
REMNANODE_SECRET_KEY="${REMNANODE_SECRET_KEY:-}"
DEFAULT_NODE_PORT="${DEFAULT_NODE_PORT:-2222}"
SELFSTEAL_DIR="${SELFSTEAL_DIR:-/opt/nginx-selfsteal-ip}"
SELFSTEAL_NGINX_SERVICE_NAME="${SELFSTEAL_NGINX_SERVICE_NAME:-nginx-selfsteal-ip}"
SELFSTEAL_PORT="${SELFSTEAL_PORT:-9443}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.28-alpine}"
NODE_IP="${NODE_IP:-${REMNANODE_IP:-}}"
LE_EMAIL="${LE_EMAIL:-}"
CERTBOT_MIN_VERSION="${CERTBOT_MIN_VERSION:-5.4.0}"
CERTBOT_STAGING="${CERTBOT_STAGING:-0}"
SNAP_SEED_WAIT_SECONDS="${SNAP_SEED_WAIT_SECONDS:-60}"
RENEW_ON_CALENDAR="${RENEW_ON_CALENDAR:-*-*-* 0/6:00:00}"
RENEW_RANDOMIZED_DELAY_SECONDS="${RENEW_RANDOMIZED_DELAY_SECONDS:-1800}"
CERTBOT_BIN=""
CONFIG_FILE="/etc/remnanode-ip-selfsteal.conf"
INSTALLED_SCRIPT="/usr/local/sbin/remnanode-ip-selfsteal"
DEPLOY_HOOK="/usr/local/sbin/remnanode-ip-selfsteal-deploy"
LOG_FILE="/var/log/remnanode-ip-selfsteal.log"
LOCK_FILE="/run/remnanode-ip-selfsteal.lock"
TIMER_NAME="remnanode-ip-selfsteal-renew"

die() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*" >&2; }
info() { echo "-- $*" >&2; }
warn() { echo "WARN: $*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
require_root() { [[ "$EUID" -eq 0 ]] || die "run with sudo/root"; }
set_status() { info "$*"; }

trim() {
  local v="${1:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# semver-ish comparison: returns 0 (true) if $1 >= $2
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

is_ipv4() {
  local ip="${1:-}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  local -a o
  read -r -a o <<< "$ip"
  for part in "${o[@]}"; do
    (( 10#$part >= 0 && 10#$part <= 255 )) || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Public IP detection
# ---------------------------------------------------------------------------
detect_public_ip() {
  local ip=""
  for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
    ip="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# certbot installation / version control
#
# apt's certbot is almost always too old for --ip-address / IP webroot
# support (needs certbot >= 5.3, ideally >= 5.4). We install via the
# official EFF-recommended snap channel, which auto-updates itself, and
# fall back to a dedicated pip venv if snapd is unavailable.
# ---------------------------------------------------------------------------
certbot_bin() {
  if [[ -x /snap/bin/certbot ]]; then
    printf '/snap/bin/certbot'
  elif [[ -x /opt/certbot-venv/bin/certbot ]]; then
    printf '/opt/certbot-venv/bin/certbot'
  elif command -v certbot >/dev/null 2>&1; then
    command -v certbot
  fi
}

# Wait for snapd to finish its initial "seeding" (base snaps, apparmor
# profiles, assertions, etc.). On a server where snapd was *just* installed,
# calling `snap install ...` immediately tends to fail with:
#   error: too early for operation, device not yet seeded or device model
#   not acknowledged
# This is the #1 reason this script fails on its very first run and then
# succeeds on the second one (by the second run snapd has already seeded).
wait_for_snap_seed() {
  command -v snap >/dev/null 2>&1 || return 0

  if timeout 5 snap wait system seed.loaded >/dev/null 2>&1; then
    ok "snapd is seeded"
    return 0
  fi

  info "waiting up to ${SNAP_SEED_WAIT_SECONDS}s for snapd to finish seeding"
  local waited=0
  while (( waited < SNAP_SEED_WAIT_SECONDS )); do
    if timeout 5 snap wait system seed.loaded >/dev/null 2>&1; then
      ok "snapd finished seeding after ${waited}s"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done

  warn "snapd did not report seeded after ${SNAP_SEED_WAIT_SECONDS}s, proceeding anyway"
  return 0
}

install_certbot_via_snap() {
  # NOTE: every external command below is redirected so it cannot write to
  # *this function's* stdout. This function only ever runs as part of
  # ensure_certbot(), and stdout chatter here has previously corrupted the
  # resolved certbot path (see CERTBOT_BIN comment above) — keep it that way
  # even if this function is refactored later.
  command -v snap >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >&2 || true
    apt-get install -y snapd >&2 || return 1
    systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  }

  wait_for_snap_seed

  snap install core >/dev/null 2>&1 || true
  snap refresh core >/dev/null 2>&1 || true
  if command -v apt-get >/dev/null 2>&1; then
    apt-get remove -y certbot >/dev/null 2>&1 || true
  fi
  snap install --classic certbot >&2 || return 1
  ln -sf /snap/bin/certbot /usr/bin/certbot
  # Give the freshly mounted snap a moment before we start calling it.
  sleep 2
  return 0
}

install_certbot_via_pip() {
  need_cmd python3
  if ! python3 -m venv /opt/certbot-venv >&2; then
    # python3-venv is often missing on minimal images; try to install it
    # before giving up.
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >&2 || true
    apt-get install -y python3-venv >/dev/null 2>&1 || true
    python3 -m venv /opt/certbot-venv >&2 || return 1
  fi
  /opt/certbot-venv/bin/pip install --upgrade pip >&2
  /opt/certbot-venv/bin/pip install "certbot>=${CERTBOT_MIN_VERSION},<6" >&2 || return 1
  ln -sf /opt/certbot-venv/bin/certbot /usr/local/bin/certbot
  return 0
}

ensure_certbot() {
  set_status CERTBOT IN_PROGRESS
  local bin
  bin="$(certbot_bin || true)"

  if [[ -z "$bin" ]]; then
    info "certbot not found, installing via snap (auto-updating channel)"
    if ! install_certbot_via_snap; then
      warn "snap install failed, falling back to pip venv"
      if ! install_certbot_via_pip; then
        set_status CERTBOT FAIL "install via snap and pip both failed"
        die "failed to install certbot via snap and pip"
      fi
    fi
    bin="$(certbot_bin || true)"
  fi
  if [[ -z "$bin" ]]; then
    set_status CERTBOT FAIL "binary not found after install"
    die "certbot binary not found after install"
  fi

  local ver
  ver="$("$bin" --version 2>/dev/null | awk '{print $2}')"
  if [[ -z "$ver" ]]; then
    set_status CERTBOT FAIL "could not parse '$bin --version'"
    die "unable to determine certbot version from '$bin --version'"
  fi

  if ! version_ge "$ver" "$CERTBOT_MIN_VERSION"; then
    warn "certbot $ver is older than required $CERTBOT_MIN_VERSION, attempting upgrade"
    if [[ "$bin" == "/snap/bin/certbot" ]]; then
      snap refresh certbot >&2 || true
    elif [[ "$bin" == "/opt/certbot-venv/bin/certbot" ]]; then
      /opt/certbot-venv/bin/pip install --upgrade "certbot>=${CERTBOT_MIN_VERSION},<6" >&2 || true
    fi
    ver="$("$bin" --version 2>/dev/null | awk '{print $2}')"
    if ! version_ge "$ver" "$CERTBOT_MIN_VERSION"; then
      set_status CERTBOT FAIL "stuck at $ver, need >=$CERTBOT_MIN_VERSION"
      die "certbot $ver still below required $CERTBOT_MIN_VERSION (IP-address certs need >=5.3, webroot-for-IP needs >=5.4)"
    fi
  fi

  set_status CERTBOT OK "v$ver at $bin"
  ok "certbot $ver is available at $bin (>= required $CERTBOT_MIN_VERSION)"
  # IMPORTANT: assign to the global instead of `printf`-ing to stdout. This
  # function must be called as a plain statement (`ensure_certbot`), never
  # as `x="$(ensure_certbot)"` — see the CERTBOT_BIN comment near the top
  # of this file for why that command-substitution pattern is unsafe here.
  CERTBOT_BIN="$bin"
}

# Persist only settings needed by renewal/deploy; never store the node secret here.
save_settings() {
  local name
  install -m 0600 /dev/null "$CONFIG_FILE"
  for name in REMNANODE_DIR REMNANODE_SERVICE_NAME COMPOSE_FILE CERT_DIR SELFSTEAL_DIR \
      SELFSTEAL_NGINX_SERVICE_NAME SELFSTEAL_PORT NODE_IP CERTBOT_STAGING; do
    printf '%s=%q\n' "$name" "${!name}" >> "$CONFIG_FILE"
  done
}

load_settings() {
  [[ -f "$CONFIG_FILE" ]] || die "run install first: $CONFIG_FILE is missing"
  # This is a root-owned, mode 0600 file written by save_settings.
  source "$CONFIG_FILE"
}

validate_settings() {
  local name value part
  local -a parts
  is_ipv4 "$NODE_IP" || die "set NODE_IP to the public IPv4 of this node"
  # Avoid octal ambiguity in Bash arithmetic / certificate names.
  IFS=. read -r -a parts <<< "$NODE_IP"
  for part in "${parts[@]}"; do
    [[ "$part" == 0 || "$part" != 0* ]] || die "IPv4 octets must not have leading zeros"
  done
  for name in SELFSTEAL_PORT DEFAULT_NODE_PORT; do
    value="${!name}"
    [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && (( value <= 65535 )) || die "invalid $name"
    [[ "$value" != 80 && "$value" != 443 ]] || die "$name cannot be 80 or 443"
  done
  [[ "$SELFSTEAL_PORT" != "$DEFAULT_NODE_PORT" ]] || die "nginx and node API ports must differ"
  for name in REMNANODE_DIR COMPOSE_FILE CERT_DIR SELFSTEAL_DIR; do
    value="${!name}"
    [[ "$value" =~ ^/[a-zA-Z0-9_./-]+$ && "$value" != / && "$value" != *'/../'* ]] || die "invalid path in $name"
  done
  for name in REMNANODE_SERVICE_NAME SELFSTEAL_NGINX_SERVICE_NAME; do
    [[ "${!name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "invalid container name: $name"
  done
  [[ "$REMNANODE_SERVICE_NAME" != "$SELFSTEAL_NGINX_SERVICE_NAME" ]] || die "container names must differ"
  for name in NGINX_IMAGE REMNANODE_IMAGE; do
    [[ "${!name}" =~ ^[a-zA-Z0-9_./:@-]+$ ]] || die "invalid image in $name"
  done
  [[ "$CERTBOT_STAGING" == 0 ]] || die "this installer requires trusted production certificates (CERTBOT_STAGING=0)"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    local installer
    installer="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$installer"
    sh "$installer"
    rm -f "$installer"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    apt-get update
    apt-get install -y docker-compose-plugin || apt-get install -y docker-compose-v2
  fi
  docker compose version >/dev/null || die "Docker Compose v2 is required"
  docker info >/dev/null || die "Docker daemon is unavailable"
}

prepare_node() {
  [[ "$MANAGE_REMNANODE" == 1 ]] || return 0
  [[ ! -f "$COMPOSE_FILE" ]] || return 0
  local secret_key="$REMNANODE_SECRET_KEY" escaped_secret
  if [[ -z "$secret_key" && -t 0 ]]; then
    read -r -s -p 'SECRET_KEY from Remnawave panel: ' secret_key
    echo >&2
  fi
  [[ -n "$secret_key" && "$secret_key" != *$'\n'* && "$secret_key" != *$'\r'* ]] || die "REMNANODE_SECRET_KEY is required for a new node"
  escaped_secret="${secret_key//\'/\'\'}"
  mkdir -p "$(dirname "$COMPOSE_FILE")" "$CERT_DIR"
  # Single-quoted YAML plus $$ prevents Compose interpolation of secret values.
  escaped_secret="${escaped_secret//\$/\$\$}"
  cat > "$COMPOSE_FILE" <<EOF
services:
  $REMNANODE_SERVICE_NAME:
    container_name: $REMNANODE_SERVICE_NAME
    hostname: $REMNANODE_SERVICE_NAME
    image: $REMNANODE_IMAGE
    restart: always
    network_mode: host
    cap_add: [NET_ADMIN]
    environment:
      NODE_PORT: "$DEFAULT_NODE_PORT"
      SECRET_KEY: '$escaped_secret'
    volumes:
      - $CERT_DIR:/var/lib/remnawave/configs/xray/ssl:ro
EOF
  chmod 0600 "$COMPOSE_FILE"
}

check_ports() {
  local port listeners own_pid=""
  # Host networking lets us identify nginx's own listeners on reinstallation.
  own_pid="$(docker inspect -f '{{.State.Pid}}' "$SELFSTEAL_NGINX_SERVICE_NAME" 2>/dev/null || true)"
  local own_pids=""
  if [[ "$own_pid" =~ ^[1-9][0-9]*$ ]]; then
    own_pids="$(docker top "$SELFSTEAL_NGINX_SERVICE_NAME" -eo pid 2>/dev/null | awk 'NR>1 {print $1}' || true)"
  fi
  for port in 80 "$SELFSTEAL_PORT"; do
    listeners="$(ss -H -ltnp "( sport = :$port )")"
    [[ -n "$listeners" ]] || continue
    local line pid owned
    while IFS= read -r line; do
      owned=0
      while IFS= read -r pid; do
        if [[ -n "$pid" && "$line" == *"pid=$pid,"* ]]; then owned=1; fi
      done <<< "$own_pids"
      (( owned == 1 )) || die "port $port is occupied by another service: $line"
    done <<< "$listeners"
  done
}

write_nginx_files() {
  local tls="${1:-0}"
  mkdir -p "$SELFSTEAL_DIR/conf" "$SELFSTEAL_DIR/html/.well-known/acme-challenge" "$SELFSTEAL_DIR/ssl"
  if [[ ! -f "$SELFSTEAL_DIR/html/index.html" ]]; then
    cat > "$SELFSTEAL_DIR/html/index.html" <<'HTML'
<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Облако файлов</title>
<style>body{font:18px system-ui;background:#f3f6fa;color:#243047;max-width:760px;margin:12vh auto;padding:24px}main{background:white;padding:40px;border-radius:20px}p{line-height:1.6}small{color:#68768b}</style>
<main><small>FILE CLOUD</small><h1>Всё важное — в одном месте</h1><p>Пространство для хранения файлов, документов и идей.</p><p>Сервис готовится к запуску. Загляните к нам позже.</p></main></html>
HTML
  fi
  cat > "$SELFSTEAL_DIR/conf/default.conf" <<EOF
server {
    listen 0.0.0.0:80 default_server;
    server_name $NODE_IP;
    root /usr/share/nginx/html;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://$NODE_IP\$request_uri; }
}
EOF
  if [[ "$tls" == 1 ]]; then
    cat >> "$SELFSTEAL_DIR/conf/default.conf" <<EOF
server {
    listen 127.0.0.1:$SELFSTEAL_PORT ssl proxy_protocol;
    http2 on;
    server_name $NODE_IP;
    ssl_certificate /etc/nginx/ssl/fullchain.crt;
    ssl_certificate_key /etc/nginx/ssl/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    root /usr/share/nginx/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  fi
  cat > "$SELFSTEAL_DIR/docker-compose.yml" <<EOF
services:
  nginx:
    image: $NGINX_IMAGE
    container_name: $SELFSTEAL_NGINX_SERVICE_NAME
    restart: always
    network_mode: host
    volumes:
      - $SELFSTEAL_DIR/conf:/etc/nginx/conf.d:ro
      - $SELFSTEAL_DIR/html:/usr/share/nginx/html:ro
      - $SELFSTEAL_DIR/ssl:/etc/nginx/ssl:ro
EOF
}

start_nginx() {
  docker compose -f "$SELFSTEAL_DIR/docker-compose.yml" up -d nginx
  local attempt
  for attempt in {1..20}; do
    if docker exec "$SELFSTEAL_NGINX_SERVICE_NAME" nginx -t; then return 0; fi
    sleep 1
  done
  die "nginx did not start; inspect docker logs $SELFSTEAL_NGINX_SERVICE_NAME"
}

check_webroot() {
  local probe="selfsteal-$(openssl rand -hex 12)" response
  printf '%s' "$probe" > "$SELFSTEAL_DIR/html/.well-known/acme-challenge/$probe"
  response="$(curl --noproxy '*' -fsS --max-time 5 "http://127.0.0.1/.well-known/acme-challenge/$probe" || true)"
  rm -f "$SELFSTEAL_DIR/html/.well-known/acme-challenge/$probe"
  [[ "$response" == "$probe" ]] || die "nginx HTTP-01 webroot is unavailable"
}

# Deploy on an actual renewal: REALITY borrows nginx TLS, so only nginx reloads.
# No RemnaNode restart is needed, and active VPN sessions remain connected.
deploy_certificate() {
  require_root
  load_settings
  local lineage="${RENEWED_LINEAGE:-${1:-}}"
  [[ "$lineage" == "/etc/letsencrypt/live/$NODE_IP" ]] || die "unexpected certificate lineage: $lineage"
  openssl x509 -in "$lineage/fullchain.pem" -noout -checkip "$NODE_IP" | grep -q 'does match' || die "certificate does not cover $NODE_IP"
  openssl x509 -in "$lineage/fullchain.pem" -noout -checkend 3600 >/dev/null || die "certificate is expired or expiring"
  local cert_pub key_pub dir
  cert_pub="$(openssl x509 -in "$lineage/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)"
  key_pub="$(openssl pkey -in "$lineage/privkey.pem" -pubout -outform DER | openssl dgst -sha256)"
  [[ "$cert_pub" == "$key_pub" ]] || die "certificate and private key do not match"
  mkdir -p "$CERT_DIR" "$SELFSTEAL_DIR/ssl"
  chmod 0700 "$CERT_DIR" "$SELFSTEAL_DIR/ssl"
  for dir in "$CERT_DIR" "$SELFSTEAL_DIR/ssl"; do
    local cert_name=fullchain.pem key_name=privkey.pem
    if [[ "$dir" == "$SELFSTEAL_DIR/ssl" ]]; then cert_name=fullchain.crt; key_name=private.key; fi
    install -m 0644 "$lineage/fullchain.pem" "$dir/$cert_name.new"
    install -m 0600 "$lineage/privkey.pem" "$dir/$key_name.new"
    mv -f "$dir/$cert_name.new" "$dir/$cert_name"
    mv -f "$dir/$key_name.new" "$dir/$key_name"
  done
  # Relative link resolves correctly inside the RemnaNode bind mount as well.
  ln -sfn privkey.pem "$CERT_DIR/privkey.key"
  if docker ps --format '{{.Names}}' | grep -Fxq "$SELFSTEAL_NGINX_SERVICE_NAME"; then
    docker exec "$SELFSTEAL_NGINX_SERVICE_NAME" nginx -t
    docker exec "$SELFSTEAL_NGINX_SERVICE_NAME" nginx -s reload
  fi
  ok "IP certificate deployed; nginx reloaded, VPN node not restarted"
}

write_panel_profile() {
  local profile="$REMNANODE_DIR/ip-selfsteal-profile.json" private_key short_id key_tmp
  # Reinstallation must not silently change REALITY credentials.
  if [[ -f "$profile" ]]; then
    if ! grep -Fq '"dest": "127.0.0.1:'"$SELFSTEAL_PORT"'"' "$profile"; then
      die "existing profile uses another target; update $profile for port $SELFSTEAL_PORT"
    fi
    info "existing panel profile preserved: $profile"
    return 0
  fi
  key_tmp="$(mktemp)"
  chmod 0600 "$key_tmp"
  openssl genpkey -algorithm X25519 -out "$key_tmp"
  private_key="$(openssl pkey -in "$key_tmp" -outform DER | tail -c 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  openssl pkey -in "$key_tmp" -pubout -outform DER | tail -c 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=' > "$REMNANODE_DIR/ip-selfsteal-public-key.txt"
  rm -f "$key_tmp"
  short_id="$(openssl rand -hex 8)"
  cat > "$profile" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "IP-SELFSTEAL-REALITY",
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {"clients": [], "decryption": "none"},
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "127.0.0.1:$SELFSTEAL_PORT",
        "xver": 1,
        "serverNames": [""],
        "privateKey": "$private_key",
        "shortIds": ["$short_id"]
      }
    }
  }],
  "outbounds": [{"tag": "DIRECT", "protocol": "freedom"}, {"tag": "BLOCK", "protocol": "blackhole"}]
}
EOF
  chmod 0600 "$profile" "$REMNANODE_DIR/ip-selfsteal-public-key.txt"
}

install_timer() {
  cat > "/etc/systemd/system/$TIMER_NAME.service" <<EOF
[Unit]
Description=Renew IP selfsteal certificate
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
[Service]
Type=oneshot
ExecStart=$INSTALLED_SCRIPT renew
EOF
  cat > "/etc/systemd/system/$TIMER_NAME.timer" <<EOF
[Unit]
Description=Check IP selfsteal certificate every six hours
[Timer]
OnCalendar=$RENEW_ON_CALENDAR
RandomizedDelaySec=$RENEW_RANDOMIZED_DELAY_SECONDS
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$TIMER_NAME.timer"
  # These predecessor timers would compete with the new certificate owner.
  local timer
  for timer in remnanode-ip-cert-renew.timer remnanode-selfsteal-cert-sync.timer; do
    if systemctl cat "$timer" >/dev/null 2>&1; then
      systemctl disable --now "$timer"
      info "replaced legacy certificate timer: $timer"
    fi
  done
}

verify_site() {
  require_root
  load_settings
  local code
  code="$(curl --noproxy '*' --connect-to "$NODE_IP:443:127.0.0.1:443" -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$NODE_IP/" )" || die "HTTPS on 443 failed; apply the generated REALITY profile in the panel"
  [[ "$code" == 200 ]] || die "website returned HTTP $code (expected 200)"
  ok "https://$NODE_IP/ returns 200 with trusted IP certificate"
}

install_all() {
  require_root
  for cmd in curl openssl ss flock timeout apt-get systemctl; do need_cmd "$cmd"; done
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another installation or renewal is running"
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  [[ -n "$NODE_IP" ]] || NODE_IP="$(detect_public_ip || true)"
  validate_settings
  ensure_docker
  check_ports
  # Existing files and an existing node container are preserved.
  prepare_node
  mkdir -p "$REMNANODE_DIR"
  ensure_certbot
  save_settings
  local source_script
  source_script="$(readlink -f "${BASH_SOURCE[0]}")"
  if [[ "$source_script" != "$INSTALLED_SCRIPT" ]]; then
    install -m 0755 "$source_script" "$INSTALLED_SCRIPT"
  fi
  printf '#!/usr/bin/env bash\nexec %q deploy "${RENEWED_LINEAGE:-${1:-}}"\n' "$INSTALLED_SCRIPT" > "$DEPLOY_HOOK"
  chmod 0755 "$DEPLOY_HOOK"

  # Keep TLS enabled during a repeat install; bootstrap HTTP only before issuance.
  local have_tls=0
  if [[ -s "$SELFSTEAL_DIR/ssl/fullchain.crt" && -s "$SELFSTEAL_DIR/ssl/private.key" ]]; then have_tls=1; fi
  write_nginx_files "$have_tls"
  start_nginx
  check_webroot

  local renewal_conf="/etc/letsencrypt/renewal/$NODE_IP.conf"
  if [[ -f "$renewal_conf" ]] && { ! grep -Fxq 'authenticator = webroot' "$renewal_conf" || ! grep -Fxq "deploy_hook = $DEPLOY_HOOK" "$renewal_conf"; }; then
    # Reconfigure uses a staging dry-run before persisting changes to an old lineage.
    "$CERTBOT_BIN" reconfigure --non-interactive --cert-name "$NODE_IP" \
      --webroot --webroot-path "$SELFSTEAL_DIR/html" --deploy-hook "$DEPLOY_HOOK"
  fi
  local -a args=(certonly --webroot --webroot-path "$SELFSTEAL_DIR/html"
    --non-interactive --agree-tos --preferred-profile shortlived
    --ip-address "$NODE_IP" --cert-name "$NODE_IP" --deploy-hook "$DEPLOY_HOOK")
  if [[ -n "$LE_EMAIL" ]]; then args+=(-m "$LE_EMAIL"); else args+=(--register-unsafely-without-email); fi
  "$CERTBOT_BIN" "${args[@]}"
  "$DEPLOY_HOOK" "/etc/letsencrypt/live/$NODE_IP"
  write_nginx_files 1
  docker exec "$SELFSTEAL_NGINX_SERVICE_NAME" nginx -t
  docker exec "$SELFSTEAL_NGINX_SERVICE_NAME" nginx -s reload
  if [[ "$MANAGE_REMNANODE" == 1 ]]; then
    docker compose -f "$COMPOSE_FILE" up -d "$REMNANODE_SERVICE_NAME"
  fi
  write_panel_profile
  install_timer
  cat <<EOF

Installation complete. Apply the profile in the Remnawave PANEL:
  $REMNANODE_DIR/ip-selfsteal-profile.json
Assign its inbound to the node and an Internal Squad, then push the profile.
Users/UUIDs are managed by Remnawave; select xtls-rprx-vision for VPN clients.
Host: address=$NODE_IP, port=443, security=reality, SNI/serverName=$NODE_IP,
      fingerprint=chrome, public key from $REMNANODE_DIR/ip-selfsteal-public-key.txt,
      shortId from the profile. Server serverNames=[""] accepts no SNI.
Site files: $SELFSTEAL_DIR/html (replace index.html with your site).
Open public TCP 80 (ACME) and TCP 443 (site/VPN); API $DEFAULT_NODE_PORT only to the panel.
After pushing the profile: sudo $INSTALLED_SCRIPT verify
EOF
}

renew_certificate() {
  require_root
  load_settings
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another installation or renewal is running"
  local certbot
  certbot="$(certbot_bin)"
  [[ -n "$certbot" ]] || die "certbot is missing"
  check_webroot
  "$certbot" renew --cert-name "$NODE_IP" --webroot --webroot-path "$SELFSTEAL_DIR/html" \
    --deploy-hook "$DEPLOY_HOOK" --quiet
}

main() {
  case "${1:-install}" in
    install|issue) install_all ;;
    renew) renew_certificate ;;
    deploy) deploy_certificate "${2:-}" ;;
    verify) verify_site ;;
    status)
      require_root
      load_settings
      openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -dates -ext subjectAltName
      systemctl status "$TIMER_NAME.timer" --no-pager
      docker ps --filter "name=$SELFSTEAL_NGINX_SERVICE_NAME"
      ;;
    help|--help|-h)
      echo "Usage: sudo NODE_IP=1.2.3.4 LE_EMAIL=you@example.com REMNANODE_SECRET_KEY=... bash $0 [install|renew|verify|status]"
      ;;
    *) die "unknown command: $1 (see --help)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
