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
SELFSTEAL_TEMPLATE="${SELFSTEAL_TEMPLATE:-random}" # 1=portfolio, 2=travel, 3=recipes
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

# Native static templates, with no remote fonts, scripts or tracking requests.
# Existing content is preserved by install; change-site replaces it explicitly.
write_site_template() {
  local selection="${1:-$SELFSTEAL_TEMPLATE}" temporary
  case "$selection" in
    random) selection="$(( RANDOM % 3 + 1 ))" ;;
    portfolio) selection=1 ;;
    travel) selection=2 ;;
    recipes) selection=3 ;;
  esac
  [[ "$selection" =~ ^[123]$ ]] || die "SELFSTEAL_TEMPLATE must be random, 1/portfolio, 2/travel, or 3/recipes"
  mkdir -p "$SELFSTEAL_DIR/html"
  temporary="$(mktemp "$SELFSTEAL_DIR/html/.index.XXXXXX")"
  case "$selection" in
    1)
      cat > "$temporary" <<'HTML'
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="Свет и форма — коллекция графических этюдов об архитектуре, пространстве и цвете."><title>Свет и форма — графические этюды</title>
<style>
:root{--paper:#f3f0e9;--ink:#252b29;--muted:#727870;--accent:#9b4e33}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.6 system-ui,sans-serif}a{color:inherit;text-decoration:none}header,main,footer{max-width:1280px;margin:auto;padding:0 6vw}header{display:flex;justify-content:space-between;align-items:center;height:100px;border-bottom:1px solid #252b2922}.logo{font-family:Georgia,serif;font-size:25px}nav{display:flex;gap:28px;font-size:13px}.hero{padding:76px 0 65px;display:grid;grid-template-columns:3fr 1fr;gap:40px;align-items:end}.eyebrow{font-size:11px;letter-spacing:.2em;text-transform:uppercase;color:var(--accent)}h1{font:clamp(46px,6vw,84px)/1.07 Georgia,serif;font-weight:400;letter-spacing:-.055em;margin:18px 0}.intro{color:var(--muted);font-size:14px;max-width:260px}.section-head{display:flex;justify-content:space-between;align-items:center;margin:16px 0 22px;font-size:12px}.works{display:grid;grid-template-columns:1fr 1fr;gap:32px}.work svg{display:block;width:100%;height:auto}.work:nth-child(2){padding-top:100px}.caption{display:flex;justify-content:space-between;align-items:center;padding:16px 0;font-size:13px}.caption span{color:var(--muted);font-size:11px}.about{margin:72px 0;display:grid;grid-template-columns:1fr 2fr;gap:30px;border-top:1px solid #252b2922;padding-top:38px}.about p{max-width:650px;margin:0;font:25px/1.5 Georgia,serif}.note{color:var(--muted);font-size:13px;margin-top:24px!important;font-family:system-ui!important}footer{padding-top:28px;padding-bottom:28px;border-top:1px solid #252b2922;display:flex;justify-content:space-between;font-size:11px;color:var(--muted)}a:hover{color:var(--accent)}a:focus-visible{outline:2px solid var(--accent);outline-offset:5px}@media(max-width:650px){header{height:80px}nav{gap:16px}.hero{padding:48px 0;grid-template-columns:1fr;gap:15px}.intro{max-width:100%}.works{grid-template-columns:1fr;gap:15px}.work:nth-child(2){padding-top:0}.about{grid-template-columns:1fr;margin:45px 0}.about p{font-size:22px}}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
</style></head><body>
<header><a class="logo" href="#">Свет и форма<span style="color:#9b4e33">.</span></a><nav aria-label="Навигация"><a href="#works">Работы</a><a href="#about">О коллекции</a></nav></header>
<main><section class="hero"><div><div class="eyebrow">Коллекция графических этюдов</div><h1>Пространство.<br>Свет. Тишина.</h1></div><p class="intro">Небольшие наблюдения о том, как простые формы складываются в истории. Архитектура, пейзаж и немного цвета.</p></section>
<section id="works"><div class="section-head"><span>ИЗБРАННЫЕ ЭТЮДЫ</span><span>01 — 04</span></div><div class="works">
<article class="work"><svg viewBox="0 0 600 660" role="img" aria-label="Графический этюд: арка и длинная тень"><rect width="600" height="660" fill="#d8c7ad"/><rect y="470" width="600" height="190" fill="#aa9475"/><path d="M140 470V250a160 160 0 0 1 320 0v220Z" fill="#eee3d0"/><path d="M210 470V255a90 90 0 0 1 180 0v215Z" fill="#4e574a"/><path d="m140 470 320 0 140 190H300Z" fill="#7d8069"/><circle cx="492" cy="88" r="35" fill="#ebd5ad"/></svg><div class="caption">Арка в полдень<span>ФОРМА / 01</span></div></article>
<article class="work"><svg viewBox="0 0 600 580" role="img" aria-label="Графический этюд: холмы и солнце"><rect width="600" height="580" fill="#c5d2cb"/><circle cx="430" cy="175" r="65" fill="#eddfba"/><path d="M0 345 180 170 350 380 490 280 600 410v170H0Z" fill="#7f9588"/><path d="M0 430 220 310 470 485 600 415v165H0Z" fill="#466454"/><path d="M0 535 200 450 380 580H0Z" fill="#b6bda0"/></svg><div class="caption">За линией холмов<span>ПЕЙЗАЖ / 02</span></div></article>
<article class="work"><svg viewBox="0 0 600 460" role="img" aria-label="Графический этюд: лестница на терракотовом фоне"><rect width="600" height="460" fill="#b97356"/><path d="M0 390h120v-80h120v-80h120v-80h120V70h120v390H0Z" fill="#efc6a2"/><path d="M0 390h120l120 70H0m120-150h120l180 150H240m0-230h120l240 190v40H420m-60-310h120l120 90v160" fill="#875943"/></svg><div class="caption">Ритм ступеней<span>АРХИТЕКТУРА / 03</span></div></article>
<article class="work"><svg viewBox="0 0 600 460" role="img" aria-label="Графический этюд: ваза у окна"><rect width="600" height="460" fill="#d8d3c4"/><rect x="330" y="40" width="210" height="270" fill="#f5eee0"/><path d="M435 40v270M330 175h210" stroke="#d8d3c4" stroke-width="14"/><rect y="350" width="600" height="110" fill="#a8ac99"/><ellipse cx="247" cy="376" rx="90" ry="20" fill="#858975"/><path d="M200 250h60l20 95q0 40-50 40t-50-40Z" fill="#a55b42"/><path d="M230 255q-30-100 30-175m-30 140q-80-50-65-100m67 46q60-70 95-52" fill="none" stroke="#58664c" stroke-width="9"/></svg><div class="caption">Утро у окна<span>СВЕТ / 04</span></div></article>
</div></section><section class="about" id="about"><div class="eyebrow">О коллекции</div><div><p>Иногда достаточно двух цветов и одной линии, чтобы вспомнить место, в котором было хорошо.</p><p class="note">Эта коллекция посвящена простым вещам: свету на стене, медленному утру и пространству между предметами. Все работы — цифровые иллюстрации.</p></div></section></main><footer><span>Свет и форма · Графические этюды</span><a href="#works">Вернуться к работам ↑</a></footer></body></html>
HTML
      ;;
    2)
      cat > "$temporary" <<'HTML'
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="Тихие маршруты — заметки о неспешных прогулках и небольших путешествиях."><title>Тихие маршруты — журнал прогулок</title><style>
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#fbf9f3;color:#283d35;font:16px/1.7 system-ui,sans-serif}a{color:inherit;text-decoration:none}.wrap{max-width:1120px;margin:auto;padding:0 32px}header{display:flex;align-items:center;justify-content:space-between;padding:30px 0;border-bottom:1px solid #d8ddd3}.brand{font:24px Georgia,serif}.brand span{margin-right:10px;color:#718668}nav{display:flex;gap:26px;font-size:13px}.hero{display:grid;grid-template-columns:1.1fr 1fr;gap:50px;padding:60px 0 48px;align-items:center}.label{font-size:11px;letter-spacing:.16em;color:#6d7e63;text-transform:uppercase}h1{font:clamp(38px,5vw,64px)/1.12 Georgia,serif;letter-spacing:-.03em;margin:20px 0}p{color:#65736a}.hero p{max-width:410px}.link{display:inline-block;border-bottom:1px solid #718668;padding-bottom:4px;font-size:13px;margin-top:15px}.map{background:#e9eee1;border-radius:130px 130px 12px 12px;overflow:hidden}.map svg{display:block;width:100%;height:auto}h2{font:32px Georgia,serif;margin:0}.heading{display:flex;justify-content:space-between;align-items:center;border-top:1px solid #d8ddd3;padding-top:32px;margin-bottom:24px}.heading span{font-size:12px;color:#83917f}.articles{display:grid;grid-template-columns:repeat(3,1fr);gap:24px}.article{padding:25px;background:#fff;border:1px solid #e0e5db;border-radius:8px}.number{font:38px Georgia;color:#bac5af}.article h3{font:23px/1.3 Georgia;margin:20px 0 12px}.article p{font-size:14px}.article details{border-top:1px solid #e4e9e0;padding-top:15px;font-size:13px}.article summary{cursor:pointer;color:#536b48}.article details p{font-size:13px}.packing{margin:48px 0;padding:32px 40px;background:#e9eee1;border-radius:8px;display:grid;grid-template-columns:1fr 1.5fr;gap:35px}.packing ul{margin:0;padding-left:20px;color:#526449;font-size:14px}.about{padding:15px 0 35px;max-width:700px}.about p{font-size:14px}footer{border-top:1px solid #d8ddd3;padding:25px 0;display:flex;justify-content:space-between;font-size:12px;color:#7a8674}a:hover{color:#8a6744}a:focus-visible,summary:focus-visible{outline:2px solid #718668;outline-offset:5px}@media(max-width:760px){.hero{grid-template-columns:1fr;gap:24px;padding-top:38px}.map{max-width:440px}.articles{grid-template-columns:1fr}.packing{grid-template-columns:1fr;padding:28px;gap:15px}.wrap{padding:0 22px}nav{gap:14px}.brand{font-size:20px}}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
</style></head><body><div class="wrap"><header><a class="brand" href="#"><span>↟</span>Тихие маршруты</a><nav aria-label="Навигация"><a href="#notes">Заметки</a><a href="#packing">С собой</a></nav></header>
<main><section class="hero"><div><div class="label">Небольшие путешествия · Большие впечатления</div><h1>Хороший день<br>начинается<br>с прогулки.</h1><p>Не обязательно уезжать далеко. Иногда новый маршрут начинается за поворотом знакомой улицы.</p><a class="link" href="#notes">Найти идею для выходного ↗</a></div><div class="map"><svg viewBox="0 0 480 440" role="img" aria-label="Иллюстрированная карта: лес, холмы и извилистая тропа"><rect width="480" height="440" fill="#e9eee1"/><path d="M0 200Q100 80 200 190T480 140V440H0Z" fill="#bcc9a6"/><path d="M0 300Q140 160 260 300T480 260V440H0Z" fill="#94ad85"/><path d="M0 385Q160 230 320 370T480 340V440H0Z" fill="#6e916b"/><path d="M220 440q-130-90 30-120t-50-100q-65-35 65-80" fill="none" stroke="#fbf9f3" stroke-width="25"/><path d="M220 440q-130-90 30-120t-50-100q-65-35 65-80" fill="none" stroke="#a99163" stroke-width="2" stroke-dasharray="5 8"/><g fill="#416948"><path d="m72 150-28 60h56Z"/><path d="m110 120-30 70h60Z"/><path d="m385 255-25 55h50Z"/><path d="m345 220-25 60h50Z"/></g><circle cx="265" cy="140" r="10" fill="#b27345"/><circle cx="265" cy="140" r="4" fill="#fbf9f3"/><circle cx="360" cy="72" r="29" fill="#eee1b0"/></svg></div></section>
<section id="notes"><div class="heading"><h2>На ближайшие выходные</h2><span>3 идеи</span></div><div class="articles">
<article class="article"><div class="number">01</div><div class="label">Город · 1–2 часа</div><h3>Незнакомая сторона знакомого города</h3><p>Выберите улицу, по которой обычно не ходите. Смотрите на окна, вывески и дворы — у города много тихих историй.</p><details><summary>Как спланировать прогулку</summary><p>Отметьте две точки на карте и соедините их небольшими улицами. Оставьте время на остановку и найдите обратный путь до начала прогулки.</p></details></article>
<article class="article"><div class="number">02</div><div class="label">Природа · Полдня</div><h3>Тропинка вдоль воды</h3><p>Набережная, озеро или небольшой ручей. Вода задаёт спокойный ритм и помогает заметить смену сезона.</p><details><summary>На что обратить внимание</summary><p>Выбирайте открытые для прогулок дорожки. После дождя берег может быть скользким; удобная обувь и короткий запасной маршрут пригодятся.</p></details></article>
<article class="article"><div class="number">03</div><div class="label">Рядом с домом · 40 минут</div><h3>Один парк, пять деталей</h3><p>Найдите необычное дерево, старую скамейку, красивую тень, новый звук и место, где хочется задержаться.</p><details><summary>Маленькое упражнение</summary><p>Сделайте по одной фотографии каждой детали. Дома выберите любимую и запишите пару слов о том, что привлекло внимание.</p></details></article>
</div></section><section class="packing" id="packing"><div><div class="label">Простой список</div><h2>Легче рюкзак —<br>легче шаг.</h2></div><ul><li>Вода и небольшой перекус.</li><li>Удобная обувь и одежда по погоде.</li><li>Заряженный телефон и сохранённая карта.</li><li>Немного свободного времени без плотного расписания.</li></ul></section><section class="about"><h2>О журнале</h2><p>«Тихие маршруты» — коллекция идей для неспешных прогулок. Здесь нет гонки за расстояниями: главное — увидеть что-нибудь новое и вернуться с хорошим настроением.</p></section></main><footer><span>Тихие маршруты · Журнал прогулок</span><a href="#">К началу ↑</a></footer></div></body></html>
HTML
      ;;
    3)
      cat > "$temporary" <<'HTML'
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="На кухне — три простых рецепта из знакомых продуктов с понятными шагами приготовления."><title>На кухне — простые рецепты на каждый день</title><style>
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#fffaf3;color:#352920;font:16px/1.7 system-ui,sans-serif}a{color:inherit;text-decoration:none}.wrap{max-width:1080px;margin:auto;padding:0 28px}header{display:flex;justify-content:space-between;align-items:center;padding:24px 0;border-bottom:1px solid #e5d9c9}.brand{font:28px Georgia,serif;color:#a6442c}nav{display:flex;gap:22px;font-size:13px}.hero{padding:50px 0;display:grid;grid-template-columns:1.2fr 1fr;gap:40px;align-items:center}.label{font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:#9a6b44}h1{font:clamp(40px,5.7vw,68px)/1.08 Georgia,serif;margin:20px 0;letter-spacing:-.04em}.hero p{color:#7e6d5e;max-width:420px}.dish{background:#eddfc5;border-radius:50%;padding:15px}.dish svg{display:block;width:100%;height:auto}.recipe-nav{display:flex;flex-wrap:wrap;gap:10px;margin:0 0 32px}.recipe-nav a{border:1px solid #dbcab4;border-radius:30px;padding:8px 18px;font-size:13px}.recipe-nav a:hover{background:#a6442c;color:white;border-color:#a6442c}.recipe{margin:0 0 26px;background:#fff;border:1px solid #e9ddce;border-radius:16px;overflow:hidden}.recipe-heading{display:flex;align-items:center;justify-content:space-between;padding:22px 30px;border-bottom:1px solid #eee5da;background:#fbf3e7;gap:20px}.recipe-heading h2{font:28px Georgia,serif;margin:0}.time{font-size:12px;white-space:nowrap;color:#946e48}.recipe-body{display:grid;grid-template-columns:1fr 1.7fr;gap:35px;padding:26px 30px}.recipe h3{font-size:11px;font-weight:600;letter-spacing:.15em;color:#9a6b44;text-transform:uppercase;margin:0 0 12px}.recipe ul,.recipe ol{padding-left:20px;margin:0;font-size:14px;color:#665344}.recipe li{margin-bottom:8px}.tip{padding:18px 30px;background:#f5f5e9;font-size:13px;color:#6a704e}.about{padding:28px 0 40px;max-width:700px}.about h2{font:30px Georgia,serif}.about p{color:#7e6d5e;font-size:14px}footer{display:flex;justify-content:space-between;gap:20px;border-top:1px solid #e5d9c9;padding:24px 0;color:#9a8672;font-size:12px}a:focus-visible{outline:2px solid #a6442c;outline-offset:4px}@media(max-width:650px){.hero{grid-template-columns:1fr;gap:20px;padding:32px 0}.dish{max-width:280px;margin:auto}.recipe-body{grid-template-columns:1fr;gap:24px;padding:24px}.recipe-heading{padding:22px;align-items:start}.recipe-heading h2{font-size:25px}.tip{padding:18px 24px}.wrap{padding:0 20px}nav{gap:14px}.brand{font-size:25px}}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
</style></head><body><div class="wrap"><header><a class="brand" href="#">На кухне<span style="color:#cda465"> ✳</span></a><nav aria-label="Навигация"><a href="#recipes">Рецепты</a><a href="#about">О сборнике</a></nav></header><main><section class="hero"><div><div class="label">Знакомые продукты · Понятные шаги</div><h1>Домашняя еда.<br>Без лишней<br>суеты.</h1><p>Три простых рецепта для тех дней, когда хочется приготовить что-то хорошее из того, что уже есть дома.</p></div><div class="dish"><svg viewBox="0 0 400 400" role="img" aria-label="Иллюстрация тарелки с пастой, томатами и листьями базилика"><circle cx="200" cy="200" r="184" fill="#fffaf0"/><circle cx="200" cy="200" r="146" fill="#ece2ca"/><circle cx="200" cy="200" r="132" fill="#f5ecd8"/><g fill="none" stroke="#d9a64c" stroke-width="14" stroke-linecap="round"><path d="M130 130q140 10 130 55t-120 60 100 30"/><path d="M110 185q30-95 85-25t90 30-30 95"/><path d="M140 270q-45-85 35-65t90 60"/><path d="M175 120q-25 80 70 65t10 115"/></g><g fill="#bd563c"><circle cx="134" cy="176" r="23"/><circle cx="256" cy="252" r="25"/><circle cx="244" cy="140" r="21"/></g><g fill="#557443"><path d="M166 247q-50-65-75-13 25 34 75 13Z"/><path d="M254 190q40-60 62-13-15 30-62 13Z"/><path d="M185 150q-35-50-55-10 16 25 55 10Z"/></g></svg></div></section><div id="recipes" class="recipe-nav"><a href="#pasta">Паста с томатами</a><a href="#potatoes">Картофель в духовке</a><a href="#oats">Овсянка с яблоком</a></div>
<article class="recipe" id="pasta"><div class="recipe-heading"><h2>Паста с томатами</h2><span class="time">25 минут · 2 порции</span></div><div class="recipe-body"><div><h3>Ингредиенты</h3><ul><li>200 г пасты</li><li>300 г томатов в собственном соку</li><li>2 зубчика чеснока</li><li>2 ст. л. оливкового масла</li><li>Соль, перец и базилик по вкусу</li></ul></div><div><h3>Приготовление</h3><ol><li>Вскипятите подсоленную воду. Варите пасту по инструкции на упаковке.</li><li>Нарежьте чеснок. Прогрейте его в масле на среднем огне около минуты, не давая подгореть.</li><li>Добавьте томаты, разомните крупные кусочки и готовьте 10–12 минут. Посолите и поперчите.</li><li>Смешайте соус с пастой. Если нужно, добавьте немного воды от варки. Подавайте с базиликом.</li></ol></div></div><div class="tip">Маленькая хитрость: сохраните полстакана воды от пасты — с ней соус лучше соединяется с макаронами.</div></article>
<article class="recipe" id="potatoes"><div class="recipe-heading"><h2>Картофель с розмарином</h2><span class="time">45 минут · 2 порции</span></div><div class="recipe-body"><div><h3>Ингредиенты</h3><ul><li>500 г картофеля</li><li>2 ст. л. растительного масла</li><li>1 ч. л. сушёного розмарина</li><li>Соль и перец по вкусу</li></ul></div><div><h3>Приготовление</h3><ol><li>Разогрейте духовку до 200 °C. Вымойте картофель и нарежьте одинаковыми дольками.</li><li>Хорошо обсушите. Смешайте с маслом, розмарином, солью и перцем.</li><li>Разложите одним слоем на противне. Запекайте 30–40 минут, один раз перевернув, до мягкости внутри и золотистых краёв.</li></ol></div></div><div class="tip">Оставьте между дольками немного места: так они запекаются равномернее.</div></article>
<article class="recipe" id="oats"><div class="recipe-heading"><h2>Овсянка с яблоком</h2><span class="time">15 минут · 1 порция</span></div><div class="recipe-body"><div><h3>Ингредиенты</h3><ul><li>50 г овсяных хлопьев</li><li>200 мл молока или воды</li><li>1 небольшое яблоко</li><li>Щепотка корицы</li><li>Мёд или сахар по желанию</li></ul></div><div><h3>Приготовление</h3><ol><li>В небольшой кастрюле доведите молоко или воду до слабого кипения.</li><li>Добавьте хлопья и готовьте по инструкции на упаковке, периодически помешивая.</li><li>Нарежьте яблоко мелкими кусочками. Добавьте в кашу за пару минут до готовности.</li><li>Снимите с огня, добавьте корицу и дайте постоять минуту под крышкой. Подсластите по вкусу.</li></ol></div></div><div class="tip">Более густую кашу легко разбавить ложкой тёплого молока уже в тарелке.</div></article>
<section class="about" id="about"><h2>Меньше сложностей. Больше вкуса.</h2><p>Этот сборник — про обычную домашнюю кухню. Простые ингредиенты, небольшие порции и рецепты, которые легко подстроить под свой вкус. Начните с одного блюда и постепенно собирайте собственную коллекцию.</p></section></main><footer><span>На кухне · Рецепты на каждый день</span><a href="#">Наверх ↑</a></footer></div></body></html>
HTML
      ;;
  esac
  chmod 0644 "$temporary"
  mv -f "$temporary" "$SELFSTEAL_DIR/html/index.html"
  printf '%s\n' "$selection" > "$SELFSTEAL_DIR/.site-template"
  ok "website template $selection written to $SELFSTEAL_DIR/html/index.html"
}

change_site() {
  require_root
  load_settings
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another installation or renewal is running"
  local selection="${1:-$SELFSTEAL_TEMPLATE}"
  # Keep a copy outside the public webroot before explicitly replacing a site.
  if [[ -f "$SELFSTEAL_DIR/html/index.html" ]]; then
    cp -a "$SELFSTEAL_DIR/html/index.html" "$SELFSTEAL_DIR/index.backup.$(date -u +%Y%m%dT%H%M%S).html"
  fi
  write_site_template "$selection"
}

write_nginx_files() {
  local tls="${1:-0}"
  mkdir -p "$SELFSTEAL_DIR/conf" "$SELFSTEAL_DIR/html/.well-known/acme-challenge" "$SELFSTEAL_DIR/ssl"
  if [[ ! -f "$SELFSTEAL_DIR/html/index.html" ]]; then
    write_site_template "$SELFSTEAL_TEMPLATE"
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
    change-site) change_site "${2:-$SELFSTEAL_TEMPLATE}" ;;
    status)
      require_root
      load_settings
      openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -dates -ext subjectAltName
      systemctl status "$TIMER_NAME.timer" --no-pager
      docker ps --filter "name=$SELFSTEAL_NGINX_SERVICE_NAME"
      ;;
    help|--help|-h)
      echo "Usage: sudo NODE_IP=1.2.3.4 LE_EMAIL=you@example.com REMNANODE_SECRET_KEY=... bash $0 [install|renew|verify|status|change-site [1|2|3|random]]"
      echo "SELFSTEAL_TEMPLATE: 1/portfolio, 2/travel, 3/recipes, random (default); install preserves an existing site."
      ;;
    *) die "unknown command: $1 (see --help)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
