#!/usr/bin/env bash
# remnanode-ip-cert.sh
#
# Issues and auto-renews a Let's Encrypt IP-address certificate (the
# "shortlived" ACME profile, ~160h / 6.67 days validity) for a RemnaNode
# host, drops it into /opt/remnanode/xray-ssl/*.pem and restarts the
# relevant docker containers whenever the certificate actually changes.
#
# Usage:
#   sudo NODE_IP=1.2.3.4 LE_EMAIL=you@example.com bash remnanode-ip-cert.sh issue
#   sudo bash remnanode-ip-cert.sh renew          # what the timer calls
#   sudo bash remnanode-ip-cert.sh install-timer  # (re)install systemd timer only
#   sudo bash remnanode-ip-cert.sh status
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment variables)
# ---------------------------------------------------------------------------
REMNANODE_DIR="${REMNANODE_DIR:-/opt/remnanode}"
REMNANODE_SERVICE_NAME="${REMNANODE_SERVICE_NAME:-remnanode}"
SELFSTEAL_NGINX_SERVICE_NAME="${SELFSTEAL_NGINX_SERVICE_NAME:-nginx-selfsteal}"
SELFSTEAL_NGINX_SSL_DIR="${SELFSTEAL_NGINX_SSL_DIR:-/opt/nginx-selfsteal/ssl}"
CERT_DIR="${CERT_DIR:-$REMNANODE_DIR/xray-ssl}"
COMPOSE_FILE="${COMPOSE_FILE:-$REMNANODE_DIR/docker-compose.yml}"

NODE_IP="${NODE_IP:-${REMNANODE_IP:-}}"
LE_EMAIL="${LE_EMAIL:-}"
CERTBOT_STAGING="${CERTBOT_STAGING:-0}"          # 1 = use LE staging (untrusted, for testing)
CERTBOT_MIN_VERSION="${CERTBOT_MIN_VERSION:-5.4.0}"
HTTP01_PORT="${HTTP01_PORT:-80}"
RESTART_ON_RENEW="${RESTART_ON_RENEW:-1}"        # 1 = docker restart remnanode(+nginx-selfsteal) after real renewal

# RemnaNode container management (only used if $COMPOSE_FILE doesn't exist yet
# or the container isn't running — mirrors moonsetup.sh's write_remnanode_files/start_remnanode)
MANAGE_REMNANODE="${MANAGE_REMNANODE:-1}"        # 0 = never touch/create the remnanode container
REMNANODE_IMAGE="${REMNANODE_IMAGE:-remnawave/node:3.1.0}"
DEFAULT_NODE_PORT="${DEFAULT_NODE_PORT:-2222}"
REMNANODE_SECRET_KEY="${REMNANODE_SECRET_KEY:-}"

RENEW_ON_CALENDAR="${RENEW_ON_CALENDAR:-*-*-* 0/6:00:00}"   # every 6h
RENEW_RANDOMIZED_DELAY_SECONDS="${RENEW_RANDOMIZED_DELAY_SECONDS:-1800}"

# How long to wait for snapd to finish its initial "seeding" before the
# very first `snap install` call. On a fresh server snapd needs a bit of
# time after being installed before it will accept snap commands; without
# this wait, the very first run of this script tends to fail with
# "device not yet seeded" and only succeeds on a second invocation.
SNAP_SEED_WAIT_SECONDS="${SNAP_SEED_WAIT_SECONDS:-60}"

DEPLOY_HOOK="/usr/local/sbin/remnanode-ip-cert-deploy.sh"
LOG_FILE="/var/log/remnanode-ip-cert.log"
STATUS_FILE="/var/log/remnanode-ip-cert.status"
LOCK_FILE="/run/remnanode-ip-cert.lock"

SERVICE_FILE="/etc/systemd/system/remnanode-ip-cert-renew.service"
TIMER_FILE="/etc/systemd/system/remnanode-ip-cert-renew.timer"

DEFAULT_CERT_FILE="$CERT_DIR/fullchain.pem"
DEFAULT_KEY_PEM="$CERT_DIR/privkey.pem"
DEFAULT_KEY_KEY="$CERT_DIR/privkey.key"

# ---------------------------------------------------------------------------
# Progress / status tracking
#
# Every stage of `issue` updates both the on-screen checklist and
# $STATUS_FILE, so the task can be followed from a *second* SSH session
# with:   watch -n2 cat /var/log/remnanode-ip-cert.status
# or:     tail -f /var/log/remnanode-ip-cert.log
# ---------------------------------------------------------------------------
STEP_TOTAL=7
STEP_CURRENT=0

STATUS_CERTBOT="PENDING";  NOTE_CERTBOT=""
STATUS_IP="PENDING";       NOTE_IP=""
STATUS_PORT80="PENDING";   NOTE_PORT80=""
STATUS_ISSUE="PENDING";    NOTE_ISSUE=""
STATUS_DEPLOY="PENDING";   NOTE_DEPLOY=""
STATUS_REMNANODE="PENDING"; NOTE_REMNANODE=""
STATUS_TIMER="PENDING";    NOTE_TIMER=""

die() { echo "FAIL: $*" >&2; exit 1; }
# ok()/info() MUST go to stderr, never stdout: several functions (ensure_certbot,
# certbot_bin, detect_public_ip) are called as `x="$(fn)"` and rely on stdout
# containing *only* their actual return value. Mixing status text into stdout
# there silently corrupts the captured value (e.g. certbot path becomes a
# multi-line string bash then fails to execute).
ok()   { echo "OK: $*" >&2; }
info() { echo "-- $*" >&2; }
warn() { echo "WARN: $*" >&2; }

step() {
  STEP_CURRENT=$((STEP_CURRENT + 1))
  echo
  echo "[${STEP_CURRENT}/${STEP_TOTAL}] $*"
}

# set_status <VAR_SUFFIX> <PENDING|IN_PROGRESS|OK|FAIL> [note]
set_status() {
  local suffix="$1" value="$2" note="${3:-}"
  printf -v "STATUS_${suffix}" '%s' "$value"
  printf -v "NOTE_${suffix}" '%s' "$note"
  {
    echo "$(date -u +%FT%TZ) ${suffix}=${value}${note:+ (${note})}"
  } >> "$STATUS_FILE" 2>/dev/null || true
}

print_summary() {
  local rc=$?
  echo
  echo "================ RemnaNode IP-cert: checklist ================"
  printf '  %-18s %s\n' "certbot:"        "${STATUS_CERTBOT}${NOTE_CERTBOT:+ (${NOTE_CERTBOT})}"
  printf '  %-18s %s\n' "public IP:"      "${STATUS_IP}${NOTE_IP:+ (${NOTE_IP})}"
  printf '  %-18s %s\n' "port 80 check:"  "${STATUS_PORT80}${NOTE_PORT80:+ (${NOTE_PORT80})}"
  printf '  %-18s %s\n' "issue cert:"     "${STATUS_ISSUE}${NOTE_ISSUE:+ (${NOTE_ISSUE})}"
  printf '  %-18s %s\n' "deploy cert:"    "${STATUS_DEPLOY}${NOTE_DEPLOY:+ (${NOTE_DEPLOY})}"
  printf '  %-18s %s\n' "remnanode up:"   "${STATUS_REMNANODE}${NOTE_REMNANODE:+ (${NOTE_REMNANODE})}"
  printf '  %-18s %s\n' "renew timer:"    "${STATUS_TIMER}${NOTE_TIMER:+ (${NOTE_TIMER})}"
  echo "================================================================"
  echo "Full log:    ${LOG_FILE}"
  echo "Status file: ${STATUS_FILE}  (tail -f it from another session to follow progress)"
  return "$rc"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root (sudo -i)"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

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
  local -a o=($ip)
  for part in "${o[@]}"; do
    (( part >= 0 && part <= 255 )) || return 1
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

  if snap wait system seed.loaded >/dev/null 2>&1; then
    ok "snapd is seeded"
    return 0
  fi

  info "waiting up to ${SNAP_SEED_WAIT_SECONDS}s for snapd to finish seeding"
  local waited=0
  while (( waited < SNAP_SEED_WAIT_SECONDS )); do
    if snap wait system seed.loaded >/dev/null 2>&1; then
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
  command -v snap >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y snapd || return 1
    systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  }

  wait_for_snap_seed

  snap install core >/dev/null 2>&1 || true
  snap refresh core >/dev/null 2>&1 || true
  if command -v apt-get >/dev/null 2>&1; then
    apt-get remove -y certbot >/dev/null 2>&1 || true
  fi
  snap install --classic certbot || return 1
  ln -sf /snap/bin/certbot /usr/bin/certbot
  # Give the freshly mounted snap a moment before we start calling it.
  sleep 2
  return 0
}

install_certbot_via_pip() {
  need_cmd python3
  if ! python3 -m venv /opt/certbot-venv 2>/dev/null; then
    # python3-venv is often missing on minimal images; try to install it
    # before giving up.
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y python3-venv >/dev/null 2>&1 || true
    python3 -m venv /opt/certbot-venv || return 1
  fi
  /opt/certbot-venv/bin/pip install --upgrade pip >/dev/null
  /opt/certbot-venv/bin/pip install "certbot>=${CERTBOT_MIN_VERSION},<6" || return 1
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
      snap refresh certbot || true
    elif [[ "$bin" == "/opt/certbot-venv/bin/certbot" ]]; then
      /opt/certbot-venv/bin/pip install --upgrade "certbot>=${CERTBOT_MIN_VERSION},<6" || true
    fi
    ver="$("$bin" --version 2>/dev/null | awk '{print $2}')"
    if ! version_ge "$ver" "$CERTBOT_MIN_VERSION"; then
      set_status CERTBOT FAIL "stuck at $ver, need >=$CERTBOT_MIN_VERSION"
      die "certbot $ver still below required $CERTBOT_MIN_VERSION (IP-address certs need >=5.3, webroot-for-IP needs >=5.4)"
    fi
  fi

  set_status CERTBOT OK "v$ver at $bin"
  ok "certbot $ver is available at $bin (>= required $CERTBOT_MIN_VERSION)"
  printf '%s' "$bin"
}

# ---------------------------------------------------------------------------
# Port 80 sanity check (standalone HTTP-01 authenticator needs it free)
# ---------------------------------------------------------------------------
ensure_port80_free() {
  need_cmd ss
  local listeners
  listeners="$(ss -H -ltnp "( sport = :${HTTP01_PORT} )" 2>/dev/null || true)"
  if [[ -n "$listeners" ]]; then
    echo "$listeners"
    set_status PORT80 FAIL "port ${HTTP01_PORT} already in use"
    die "port ${HTTP01_PORT} is already in use; free it (or set HTTP01_PORT to another port that is reachable from the internet on 80) before issuing/renewing"
  fi
  set_status PORT80 OK "port ${HTTP01_PORT} is free"
}

# ---------------------------------------------------------------------------
# Deploy hook: installs the freshly (re)issued cert into place and restarts
# whatever needs the new files. Certbot only calls --deploy-hook when a
# certificate is *actually* renewed, never on a no-op check, and it also
# persists the hook path into the lineage's renewal config, so any future
# `certbot renew` (ours or a generic one) will keep calling it.
# ---------------------------------------------------------------------------
write_deploy_hook_script() {
  mkdir -p "$(dirname "$DEPLOY_HOOK")"
  cat > "$DEPLOY_HOOK" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail

CERT_DIR="${CERT_DIR}"
SELFSTEAL_NGINX_SSL_DIR="${SELFSTEAL_NGINX_SSL_DIR}"
REMNANODE_SERVICE_NAME="${REMNANODE_SERVICE_NAME}"
SELFSTEAL_NGINX_SERVICE_NAME="${SELFSTEAL_NGINX_SERVICE_NAME}"
COMPOSE_FILE="${COMPOSE_FILE}"
RESTART_ON_RENEW="${RESTART_ON_RENEW}"
LOG_FILE="${LOG_FILE}"
LOCK_FILE="${LOCK_FILE}"

log() { echo "[\$(date -u +%FT%TZ)] \$*" | tee -a "\$LOG_FILE" >&2; }

# certbot sets RENEWED_LINEAGE when calling this as --deploy-hook. Allow a
# manual override as \$1 for the very first (non-renewal) issuance.
LINEAGE="\${RENEWED_LINEAGE:-\${1:-}}"
[[ -n "\$LINEAGE" && -d "\$LINEAGE" ]] || { log "FAIL: no lineage directory given"; exit 1; }

exec 9>"\$LOCK_FILE"
flock -n 9 || { log "another deploy run is in progress, skipping"; exit 0; }

mkdir -p "\$CERT_DIR"
stamp="\$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -f "\$CERT_DIR/fullchain.pem" ]]; then
  cp -a "\$CERT_DIR" "\${CERT_DIR}.backup.\$stamp"
fi

install -m 0644 "\$LINEAGE/fullchain.pem" "\$CERT_DIR/fullchain.pem"
install -m 0600 "\$LINEAGE/privkey.pem"   "\$CERT_DIR/privkey.pem"
ln -sfn "\$CERT_DIR/privkey.pem" "\$CERT_DIR/privkey.key"
log "installed cert from \$LINEAGE into \$CERT_DIR"

if [[ -d "\$SELFSTEAL_NGINX_SSL_DIR" ]]; then
  install -m 0644 "\$LINEAGE/fullchain.pem" "\$SELFSTEAL_NGINX_SSL_DIR/fullchain.crt"
  install -m 0600 "\$LINEAGE/privkey.pem"   "\$SELFSTEAL_NGINX_SSL_DIR/private.key"
  log "installed cert into \$SELFSTEAL_NGINX_SSL_DIR"
  if docker ps --format '{{.Names}}' | grep -qx "\$SELFSTEAL_NGINX_SERVICE_NAME"; then
    if docker exec "\$SELFSTEAL_NGINX_SERVICE_NAME" nginx -t >>"\$LOG_FILE" 2>&1; then
      docker exec "\$SELFSTEAL_NGINX_SERVICE_NAME" nginx -s reload >>"\$LOG_FILE" 2>&1 || true
      log "nginx-selfsteal config test ok, reloaded"
    else
      log "WARN: nginx -t failed inside \$SELFSTEAL_NGINX_SERVICE_NAME, not reloading"
    fi
  fi
fi

if [[ "\$RESTART_ON_RENEW" == "1" ]]; then
  if docker ps --format '{{.Names}}' | grep -qx "\$REMNANODE_SERVICE_NAME"; then
    if [[ -f "\$COMPOSE_FILE" ]]; then
      ( cd "\$(dirname "\$COMPOSE_FILE")" && docker compose restart "\$REMNANODE_SERVICE_NAME" ) >>"\$LOG_FILE" 2>&1
    else
      docker restart "\$REMNANODE_SERVICE_NAME" >>"\$LOG_FILE" 2>&1
    fi
    log "restarted \$REMNANODE_SERVICE_NAME to pick up new certificate"
  fi
fi

log "deploy completed successfully"
EOF2
  chmod 0755 "$DEPLOY_HOOK"
  ok "deploy hook written: $DEPLOY_HOOK"
}

# ---------------------------------------------------------------------------
# RemnaNode container: install docker if needed, write a minimal compose file
# only if one doesn't already exist, and make sure the container is up.
# (Mirrors write_remnanode_files/start_remnanode from moonsetup.sh — if you
# already ran moonsetup.sh, $COMPOSE_FILE exists and this just does
# `docker compose up -d` / leaves your file untouched.)
# ---------------------------------------------------------------------------
ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    info "docker not found, installing via get.docker.com"
    curl -fsSL https://get.docker.com | sh
  fi
  command -v docker >/dev/null 2>&1 || die "docker installation failed"

  if ! docker compose version >/dev/null 2>&1; then
    info "docker compose v2 not found, installing plugin"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y docker-compose-plugin || apt-get install -y docker-compose-v2 || true
  fi
  docker compose version >/dev/null 2>&1 || die "docker compose v2 is required but could not be installed"
}

write_remnanode_compose() {
  local secret_key="$1"
  local escaped_secret="${secret_key//\\/\\\\}"
  escaped_secret="${escaped_secret//\"/\\\"}"

  mkdir -p "$REMNANODE_DIR" "$CERT_DIR"
  chmod 700 "$CERT_DIR" || true

  cat > "$COMPOSE_FILE" <<EOF2
services:
  ${REMNANODE_SERVICE_NAME}:
    container_name: ${REMNANODE_SERVICE_NAME}
    hostname: ${REMNANODE_SERVICE_NAME}
    image: ${REMNANODE_IMAGE}
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      NODE_PORT: "${DEFAULT_NODE_PORT}"
      SECRET_KEY: "${escaped_secret}"
    volumes:
      - ./xray-ssl:/var/lib/remnawave/configs/xray/ssl
EOF2

  ok "written: $COMPOSE_FILE"
}

ensure_remnanode_running() {
  if [[ "$MANAGE_REMNANODE" != "1" ]]; then
    set_status REMNANODE OK "MANAGE_REMNANODE=0, skipped"
    return 0
  fi

  set_status REMNANODE IN_PROGRESS
  ensure_docker

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    info "no compose file at $COMPOSE_FILE yet, creating one"
    local secret_key="$REMNANODE_SECRET_KEY"
    if [[ -z "$secret_key" ]]; then
      # stdout is redirected to tee at this point in issue_certificate, but
      # /dev/tty is still the real terminal, so an interactive prompt works.
      if [[ -r /dev/tty ]]; then
        read -r -p "Paste SECRET_KEY from the Remnawave panel: " secret_key < /dev/tty || true
      fi
    fi
    secret_key="$(trim "${secret_key//$'\r'/}")"
    if [[ -z "$secret_key" ]]; then
      set_status REMNANODE FAIL "SECRET_KEY not provided"
      die "SECRET_KEY is required to create $COMPOSE_FILE (set REMNANODE_SECRET_KEY=... or run interactively)"
    fi
    write_remnanode_compose "$secret_key"
  else
    info "compose file already exists at $COMPOSE_FILE, leaving it as-is"
  fi

  ( cd "$REMNANODE_DIR" && docker compose up -d "$REMNANODE_SERVICE_NAME" )

  sleep 2
  if docker ps --format '{{.Names}}' | grep -qx "$REMNANODE_SERVICE_NAME"; then
    set_status REMNANODE OK "container is running"
    ok "$REMNANODE_SERVICE_NAME is up"
  else
    set_status REMNANODE FAIL "container did not start, check: docker compose -f $COMPOSE_FILE logs"
    die "$REMNANODE_SERVICE_NAME did not start; check 'docker compose -f $COMPOSE_FILE logs'"
  fi
}

# ---------------------------------------------------------------------------
# Issue the certificate for the first time
# ---------------------------------------------------------------------------
issue_certificate() {
  require_root
  need_cmd curl
  mkdir -p "$CERT_DIR" "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" "$STATUS_FILE"
  trap print_summary EXIT

  # Guarded: on a brand-new server docker may not exist yet at this point
  # (it gets installed later by ensure_docker), so `docker ps` here would
  # otherwise abort the whole script under `set -e` before certbot is even
  # touched.
  if command -v docker >/dev/null 2>&1; then
    dockerpsq="$(docker ps -q || true)"
    if [[ -n "$dockerpsq" ]]; then
      docker stop $dockerpsq
    fi
    echo "ALLCONTSTOPPED"
  else
    info "docker not installed yet, nothing to stop"
  fi

  # Mirror everything to the log file so the run can be followed with
  # `tail -f /var/log/remnanode-ip-cert.log` from a second SSH session.
  exec > >(tee -a "$LOG_FILE") 2>&1

  echo "Starting at $(date -u +%FT%TZ). Follow progress from another session with:"
  echo "  tail -f ${LOG_FILE}"
  echo "  watch -n2 cat ${STATUS_FILE}"

  step "Installing / verifying certbot (needs >= ${CERTBOT_MIN_VERSION} for IP certs)"
  local certbot
  certbot="$(ensure_certbot)"

  step "Detecting public IPv4 address"
  set_status IP IN_PROGRESS
  if [[ -z "$NODE_IP" ]]; then
    info "NODE_IP not set, auto-detecting public IPv4"
    NODE_IP="$(detect_public_ip || true)"
  fi
  if ! is_ipv4 "$NODE_IP"; then
    set_status IP FAIL "could not auto-detect a valid IPv4"
    die "could not determine a valid public IPv4 address (set NODE_IP=1.2.3.4 explicitly)"
  fi
  set_status IP OK "$NODE_IP"
  ok "using IP address: $NODE_IP"

  step "Checking that port ${HTTP01_PORT} is free for the HTTP-01 challenge"
  ensure_port80_free
  write_deploy_hook_script

  step "Requesting the IP certificate from Let's Encrypt (profile: shortlived, ~160h validity)"
  set_status ISSUE IN_PROGRESS
  local -a args=(
    certonly --standalone --non-interactive --agree-tos
    --preferred-profile shortlived
    --http-01-port "$HTTP01_PORT"
    --ip-address "$NODE_IP"
    --cert-name "$NODE_IP"
    --deploy-hook "$DEPLOY_HOOK"
  )
  if [[ -n "$LE_EMAIL" ]]; then
    args+=(-m "$LE_EMAIL")
  else
    warn "LE_EMAIL not set; using --register-unsafely-without-email (you will not get expiry/ARI notices from Let's Encrypt)"
    args+=(--register-unsafely-without-email)
  fi
  if [[ "$CERTBOT_STAGING" == "1" ]]; then
    warn "issuing a STAGING (untrusted) certificate because CERTBOT_STAGING=1"
    args+=(--staging)
  fi

  if ! "$certbot" "${args[@]}"; then
    set_status ISSUE FAIL "certonly failed, see /var/log/letsencrypt/letsencrypt.log"
    die "certbot certonly failed, see /var/log/letsencrypt/letsencrypt.log"
  fi
  set_status ISSUE OK "certificate obtained for $NODE_IP"

  step "Deploying the certificate into ${CERT_DIR} and restarting containers"
  set_status DEPLOY IN_PROGRESS
  # --deploy-hook only fires on *renewal*, so run it once manually now to
  # populate $CERT_DIR with the certificate we just issued.
  if ! "$DEPLOY_HOOK" "/etc/letsencrypt/live/${NODE_IP}"; then
    set_status DEPLOY FAIL "deploy hook returned non-zero"
    die "initial deploy step failed"
  fi
  set_status DEPLOY OK "installed into ${CERT_DIR}"

  step "Making sure the RemnaNode container is up"
  ensure_remnanode_running

  step "Installing the systemd renewal timer"
  set_status TIMER IN_PROGRESS
  install_renew_timer
  set_status TIMER OK "${RENEW_ON_CALENDAR} (+${RENEW_RANDOMIZED_DELAY_SECONDS}s)"

  echo
  ok "IP certificate issued and installed"
  echo "  cert: $DEFAULT_CERT_FILE"
  rm -f /opt/remnanode/xray-ssl/privkey.key
  cp /opt/remnanode/xray-ssl/privkey.pem /opt/remnanode/xray-ssl/privkey.key
  echo "  key:  $DEFAULT_KEY_KEY -> COPIED $DEFAULT_KEY_PEM"
  echo
  echo "Panel / Xray inbound TLS settings should point to:"
  echo "  certificates[0].certificateFile: \"/var/lib/remnawave/configs/xray/ssl/fullchain.pem\""
  echo "  certificates[0].keyFile:         \"/var/lib/remnawave/configs/xray/ssl/privkey.key\""
  echo
  echo "Certificate is short-lived (~6.6 days). A systemd timer will attempt renewal"
  echo "every 6h and Let's Encrypt/certbot will actually renew it once ~half its"
  echo "lifetime remains, then restart ${REMNANODE_SERVICE_NAME} automatically."
}

# ---------------------------------------------------------------------------
# systemd timer for periodic renewal checks
# ---------------------------------------------------------------------------
install_renew_timer() {
  require_root
  local certbot
  certbot="$(certbot_bin)"
  [[ -n "$certbot" ]] || die "certbot not installed yet; run 'issue' first"
  [[ -n "$NODE_IP" ]] || die "NODE_IP is required to scope the renewal timer"

  cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=Renew RemnaNode Let's Encrypt IP certificate (${NODE_IP})
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$0 renew
Environment=NODE_IP=${NODE_IP}
Environment=REMNANODE_DIR=${REMNANODE_DIR}
Environment=REMNANODE_SERVICE_NAME=${REMNANODE_SERVICE_NAME}
Environment=SELFSTEAL_NGINX_SERVICE_NAME=${SELFSTEAL_NGINX_SERVICE_NAME}
Environment=SELFSTEAL_NGINX_SSL_DIR=${SELFSTEAL_NGINX_SSL_DIR}
Environment=CERT_DIR=${CERT_DIR}
Environment=COMPOSE_FILE=${COMPOSE_FILE}
Environment=RESTART_ON_RENEW=${RESTART_ON_RENEW}
Environment=HTTP01_PORT=${HTTP01_PORT}
EOF2

  cat > "$TIMER_FILE" <<EOF2
[Unit]
Description=Periodic check/renewal of RemnaNode IP certificate (${NODE_IP})

[Timer]
OnCalendar=${RENEW_ON_CALENDAR}
RandomizedDelaySec=${RENEW_RANDOMIZED_DELAY_SECONDS}
Persistent=true

[Install]
WantedBy=timers.target
EOF2

  chmod 0644 "$SERVICE_FILE" "$TIMER_FILE"
  systemctl daemon-reload
  systemctl enable --now remnanode-ip-cert-renew.timer
  ok "renewal timer enabled: ${RENEW_ON_CALENDAR} (+${RENEW_RANDOMIZED_DELAY_SECONDS}s random delay)"
}

# ---------------------------------------------------------------------------
# Called by the timer: only actually renews (and deploys) when due
# ---------------------------------------------------------------------------
renew_certificate() {
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" "$STATUS_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1

  echo "[$(date -u +%FT%TZ)] renew check starting for ${NODE_IP:-<unset>}"
  local certbot
  certbot="$(certbot_bin)"
  [[ -n "$certbot" ]] || die "certbot not installed; run 'issue' first"
  [[ -n "$NODE_IP" ]] || die "NODE_IP is required (was it set when the timer was installed?)"

  ensure_port80_free

  local -a args=(renew --cert-name "$NODE_IP" --http-01-port "$HTTP01_PORT" --quiet)
  if [[ "$CERTBOT_STAGING" == "1" ]]; then
    args+=(--staging)
  fi

  if "$certbot" "${args[@]}"; then
    set_status RENEW_LAST OK "$(date -u +%FT%TZ)"
    ok "renew check completed for ${NODE_IP} (deploy-hook runs automatically if it actually renewed)"
  else
    set_status RENEW_LAST FAIL "$(date -u +%FT%TZ)"
    die "certbot renew failed for ${NODE_IP}, see ${LOG_FILE}"
  fi
}

status() {
  local certbot
  certbot="$(certbot_bin || true)"
  [[ -n "$certbot" ]] || die "certbot not installed"
  "$certbot" certificates || true
  echo
  echo "-- last recorded status events (${STATUS_FILE}) --"
  tail -n 20 "$STATUS_FILE" 2>/dev/null || echo "(no status file yet — run 'issue' first)"
  echo
  systemctl status remnanode-ip-cert-renew.timer --no-pager 2>/dev/null || warn "timer not installed yet"
  systemctl list-timers 'remnanode-ip-cert-renew.timer' --no-pager 2>/dev/null || true
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    issue) issue_certificate ;;
    renew) renew_certificate ;;
    install-timer) install_renew_timer ;;
    status) status ;;
    *)
      cat <<USAGE
Usage: $0 <command>

  issue           Install certbot (if needed), issue the IP certificate,
                   deploy it into $CERT_DIR, and install the renewal timer.
  renew           Run a renewal check now (this is what the timer calls).
  install-timer   (Re)install the systemd timer only.
  status          Show certbot certificate info + timer status.

Useful env vars: NODE_IP, LE_EMAIL, CERTBOT_STAGING=1, RESTART_ON_RENEW=0,
                 REMNANODE_DIR, REMNANODE_SERVICE_NAME, SELFSTEAL_NGINX_SERVICE_NAME,
                 MANAGE_REMNANODE=0 (skip creating/starting the container),
                 REMNANODE_SECRET_KEY=... (avoid the interactive prompt),
                 SNAP_SEED_WAIT_SECONDS=60 (max wait for snapd seeding on first run).

Track progress of a running 'issue'/'renew' from another SSH session with:
  tail -f ${LOG_FILE}
  watch -n2 cat ${STATUS_FILE}
USAGE
      exit 1
      ;;
  esac
}

main "$@"
