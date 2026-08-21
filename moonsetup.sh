#!/usr/bin/env bash
set -Eeuo pipefail

SELFSTEAL_SCRIPT_URL="${SELFSTEAL_SCRIPT_URL:-https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh}"
REMNANODE_DIR="${REMNANODE_DIR:-/opt/remnanode}"
REMNANODE_IMAGE="${REMNANODE_IMAGE:-remnawave/node:3.1.0}"
REMNANODE_SERVICE_NAME="${REMNANODE_SERVICE_NAME:-remnanode}"
DEFAULT_NODE_PORT="${DEFAULT_NODE_PORT:-2222}"
DEFAULT_SELFSTEAL_PORT="${DEFAULT_SELFSTEAL_PORT:-9443}"
DEFAULT_SELFSTEAL_TEMPLATE="${DEFAULT_SELFSTEAL_TEMPLATE:-1}"
SELFSTEAL_BASE_DOMAIN="${SELFSTEAL_BASE_DOMAIN:-pinkmoon.pro}"
DEFAULT_SELFSTEAL_SUBDOMAIN="${DEFAULT_SELFSTEAL_SUBDOMAIN:-nld}"
DEFAULT_SELFSTEAL_DOMAIN="${DEFAULT_SELFSTEAL_DOMAIN:-${DEFAULT_SELFSTEAL_SUBDOMAIN}.${SELFSTEAL_BASE_DOMAIN}}"
CERT_REQUIRED_DNS_PATTERN="${CERT_REQUIRED_DNS_PATTERN:-*.pinkmoon.pro}"
CERT_WAIT_SECONDS="${CERT_WAIT_SECONDS:-600}"
CERT_HELPER_TAG="${CERT_HELPER_TAG:-}"
CERT_HELPER_TAG_STRICT="${CERT_HELPER_TAG_STRICT:-0}"
CERT_SYNC_ENABLED="${CERT_SYNC_ENABLED:-1}"
CERT_SYNC_TIMER_ENABLED="${CERT_SYNC_TIMER_ENABLED:-1}"
CERT_SYNC_ON_CALENDAR="${CERT_SYNC_ON_CALENDAR:-*-*-* 04:17:00}"
CERT_SYNC_RANDOMIZED_DELAY_SECONDS="${CERT_SYNC_RANDOMIZED_DELAY_SECONDS:-3600}"
SELFSTEAL_NGINX_SERVICE_NAME="${SELFSTEAL_NGINX_SERVICE_NAME:-nginx-selfsteal}"
SELFSTEAL_NGINX_SSL_DIR="${SELFSTEAL_NGINX_SSL_DIR:-/opt/nginx-selfsteal/ssl}"

CERT_DIR="$REMNANODE_DIR/xray-ssl"
COMPOSE_FILE="$REMNANODE_DIR/docker-compose.yml"
DEFAULT_CERT_FILE="$CERT_DIR/fullchain.pem"
DEFAULT_KEY_PEM="$CERT_DIR/privkey.pem"
DEFAULT_KEY_KEY="$CERT_DIR/privkey.key"

STATUS_NODE="PENDING"
STATUS_SELFSTEAL="PENDING"
STATUS_OPTIMIZATION="PENDING"
STATUS_SCANNER="PENDING"
NOTE_NODE=""
NOTE_SELFSTEAL=""
NOTE_OPTIMIZATION=""
NOTE_SCANNER=""
RUN_NODE=1
RUN_SELFSTEAL=1
RUN_OPTIMIZATION=1
RUN_SCANNER=1
RUN_CERT_SYNC=0
INSTALL_MODE_NAME="full"

die() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }
info() { echo "-- $*"; }
warn() { echo "WARN: $*"; }

wait_for_apt_locks() {
  local timeout="${1:-600}"
  local waited=0
  local interval=5

  if ! command -v fuser >/dev/null 2>&1; then
    warn "fuser is not available; skipping apt lock wait"
    return 0
  fi

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
    || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
    || fuser /var/cache/apt/archives/lock >/dev/null 2>&1 \
    || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if (( waited == 0 )); then
      warn "apt/dpkg is busy (likely unattended-upgrades), waiting for lock release..."
    fi
    if (( waited >= timeout )); then
      die "apt/dpkg lock was not released in ${timeout}s"
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done

  if (( waited > 0 )); then
    ok "apt/dpkg lock released after ${waited}s"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "run as root (sudo -i)"
  fi
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt_default() {
  local var_name="$1"
  local question="$2"
  local default_value="$3"
  local value=""
  read -r -p "$question" value || true
  value="$(trim "$value")"
  if [[ -z "$value" ]]; then
    value="$default_value"
  fi
  printf -v "$var_name" '%s' "$value"
}

normalize_selfsteal_domain() {
  local value
  local base

  value="$(trim "${1:-}")"
  base="$(trim "${SELFSTEAL_BASE_DOMAIN:-}")"
  base="${base#.}"

  if [[ -z "$value" ]]; then
    return 0
  fi

  if [[ "$value" != *.* && -n "$base" ]]; then
    printf '%s.%s' "$value" "$base"
    return 0
  fi

  printf '%s' "$value"
}

selfsteal_domain_prompt_value() {
  local domain
  local base
  local suffix
  local subdomain

  domain="$(normalize_selfsteal_domain "${1:-}")"
  base="$(trim "${SELFSTEAL_BASE_DOMAIN:-}")"
  base="${base#.}"
  suffix=".${base}"

  if [[ -n "$base" && "$domain" == *"$suffix" ]]; then
    subdomain="${domain%"$suffix"}"
    if [[ -n "$subdomain" && "$subdomain" != *.* ]]; then
      printf '%s' "$subdomain"
      return 0
    fi
  fi

  printf '%s' "$domain"
}

detect_selfsteal_domain_from_active_config() {
  local log_file="/tmp/remnanode-servername-detect.log"
  local detected=""

  if ! docker ps --format '{{.Names}}' | grep -qx "$REMNANODE_SERVICE_NAME"; then
    return 1
  fi

  if ! detected="$(docker exec -i \
    -e BASE_DOMAIN="$SELFSTEAL_BASE_DOMAIN" \
    -e CERT_TAG="$CERT_HELPER_TAG" \
    -e CERT_TAG_STRICT="$CERT_HELPER_TAG_STRICT" \
    "$REMNANODE_SERVICE_NAME" sh 2>"$log_file" <<'EOSH'
set -eu

SOCK="$(tr '\0' '\n' </proc/1/environ | sed -n 's/^INTERNAL_SOCKET_PATH=//p' | head -n1)"
TOK="$(tr '\0' '\n' </proc/1/environ | sed -n 's/^INTERNAL_REST_TOKEN=//p' | head -n1)"
[ -n "$SOCK" ] && [ -n "$TOK" ] || exit 11

SOCK="$SOCK" TOK="$TOK" BASE_DOMAIN="${BASE_DOMAIN:-}" CERT_TAG="${CERT_TAG:-}" CERT_TAG_STRICT="${CERT_TAG_STRICT:-0}" node <<'NODE'
const http = require('http');

const socketPath = process.env.SOCK;
const token = process.env.TOK;
const baseDomain = (process.env.BASE_DOMAIN || '').trim().toLowerCase().replace(/^\./, '');
const certTag = (process.env.CERT_TAG || '').trim();
const certTagStrict = (process.env.CERT_TAG_STRICT || '').trim() === '1';

function isApiInbound(ib) {
  const tag = String(ib?.tag || '').toUpperCase();
  return tag === 'REMNAWAVE_API_INBOUND' || tag.includes('API_INBOUND');
}

function isBaseDomainMatch(name) {
  const lower = name.toLowerCase();
  return baseDomain && (lower === baseDomain || lower.endsWith(`.${baseDomain}`));
}

http.get({ socketPath, path: `/internal/get-config?token=${token}` }, (res) => {
  let raw = '';
  res.on('data', (chunk) => {
    raw += chunk;
  });
  res.on('end', () => {
    let cfg;
    try {
      cfg = JSON.parse(raw || '{}');
    } catch {
      process.exit(12);
    }

    const inbounds = Array.isArray(cfg?.inbounds) ? cfg.inbounds : [];
    const candidates = [];

    inbounds.forEach((ib, inboundIndex) => {
      if (certTagStrict && certTag && ib?.tag !== certTag) return;

      const names = ib?.streamSettings?.realitySettings?.serverNames;
      if (!Array.isArray(names)) return;

      names.forEach((rawName, nameIndex) => {
        const name = String(rawName || '').trim();
        if (!name || name.includes('*')) return;

        let score = 0;
        if (certTag && ib?.tag === certTag) score += 1000;
        if (!isApiInbound(ib)) score += 100;
        if (isBaseDomainMatch(name)) score += 50;
        if (Number(ib?.port) === 443) score += 10;

        candidates.push({ name, score, order: inboundIndex * 1000 + nameIndex });
      });
    });

    if (candidates.length === 0) {
      process.exit(13);
    }

    candidates.sort((a, b) => b.score - a.score || a.order - b.order);
    process.stdout.write(candidates[0].name);
  });
}).on('error', () => {
  process.exit(14);
});
NODE
EOSH
  )"; then
    return 1
  fi

  detected="$(trim "$detected")"
  [[ -n "$detected" ]] || return 1
  printf '%s' "$detected"
}

is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_int_1_11() {
  [[ "${1:-}" =~ ^([1-9]|1[0-1])$ ]]
}

set_install_mode_flags() {
  local mode="$1"
  case "$mode" in
    1)
      RUN_NODE=1
      RUN_SELFSTEAL=1
      RUN_OPTIMIZATION=1
      RUN_SCANNER=1
      INSTALL_MODE_NAME="full"
      ;;
    2)
      RUN_NODE=1
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=0
      RUN_SCANNER=0
      INSTALL_MODE_NAME="remnanode_only"
      ;;
    3)
      RUN_NODE=0
      RUN_SELFSTEAL=1
      RUN_OPTIMIZATION=0
      RUN_SCANNER=0
      INSTALL_MODE_NAME="selfsteal_only"
      ;;
    4)
      RUN_NODE=1
      RUN_SELFSTEAL=1
      RUN_OPTIMIZATION=0
      RUN_SCANNER=0
      INSTALL_MODE_NAME="node_and_selfsteal"
      ;;
    5)
      RUN_NODE=1
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=1
      RUN_SCANNER=1
      INSTALL_MODE_NAME="node_opt_scanner"
      ;;
    6)
      RUN_NODE=0
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=1
      RUN_SCANNER=1
      INSTALL_MODE_NAME="opt_and_scanner_only"
      ;;
    7)
      RUN_NODE=0
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=1
      RUN_SCANNER=0
      INSTALL_MODE_NAME="optimization_only"
      ;;
    8)
      RUN_NODE=0
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=0
      RUN_SCANNER=1
      INSTALL_MODE_NAME="scanner_only"
      ;;
    9)
      RUN_NODE=0
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=0
      RUN_SCANNER=0
      RUN_CERT_SYNC=1
      INSTALL_MODE_NAME="cert_sync_only"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

select_install_mode() {
  local mode="${INSTALL_MODE:-}"
  mode="$(trim "$mode")"

  if [[ -z "$mode" ]]; then
    echo
    echo "Select installation mode:"
    echo "  1) Full install (remnanode + selfsteal + optimization + scanner protection)"
    echo "  2) Only remnanode"
    echo "  3) Only selfsteal"
    echo "  4) Remnanode + selfsteal"
    echo "  5) Remnanode + optimization + scanner protection"
    echo "  6) Only optimization + scanner protection"
    echo "  7) Only optimization (BBR)"
    echo "  8) Only scanner protection (traffic-guard)"
    echo "  9) Only selfsteal cert sync timer"
    read -r -p "Mode [1]: " mode || true
    mode="$(trim "$mode")"
  fi

  if [[ -z "$mode" ]]; then
    mode="1"
  fi

  set_install_mode_flags "$mode" || die "invalid mode: $mode"
  ok "selected mode: ${mode} (${INSTALL_MODE_NAME})"
}

mark_skipped_steps() {
  if [[ "$RUN_NODE" -eq 0 ]]; then
    STATUS_NODE="SKIPPED"
    NOTE_NODE="not selected"
  fi
  if [[ "$RUN_SELFSTEAL" -eq 0 ]]; then
    STATUS_SELFSTEAL="SKIPPED"
    NOTE_SELFSTEAL="not selected"
  fi
  if [[ "$RUN_OPTIMIZATION" -eq 0 ]]; then
    STATUS_OPTIMIZATION="SKIPPED"
    NOTE_OPTIMIZATION="not selected"
  fi
  if [[ "$RUN_SCANNER" -eq 0 ]]; then
    STATUS_SCANNER="SKIPPED"
    NOTE_SCANNER="not selected"
  fi
}

print_summary() {
  echo
  echo "Checklist:"
  echo "- Нода: ${STATUS_NODE}${NOTE_NODE:+ (${NOTE_NODE})}"
  echo "- Селфстил: ${STATUS_SELFSTEAL}${NOTE_SELFSTEAL:+ (${NOTE_SELFSTEAL})}"
  echo "- Оптимизация сервера: ${STATUS_OPTIMIZATION}${NOTE_OPTIMIZATION:+ (${NOTE_OPTIMIZATION})}"
  echo "- Защита от сканеров: ${STATUS_SCANNER}${NOTE_SCANNER:+ (${NOTE_SCANNER})}"
}
trap print_summary EXIT

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp "$file" "${file}.bak_${ts}"
    ok "backup created: ${file}.bak_${ts}"
  fi
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    ok "docker is already installed"
  else
    info "installing docker via official script"
    curl -fsSL https://get.docker.com | sh
    ok "docker installed"
  fi

  ensure_docker_compose_v2 || die "docker compose v2 is required"
}

ensure_docker_compose_v2() {
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose v2 is available"
    return 0
  fi

  warn "docker compose v2 is not available; attempting to install compose plugin"

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    wait_for_apt_locks 900
    apt-get update -y || true
    wait_for_apt_locks 900
    if ! apt-get install -y docker-compose-plugin >/tmp/remnanode-compose-install.log 2>&1; then
      apt-get install -y docker-compose-v2 >>/tmp/remnanode-compose-install.log 2>&1 || true
    fi
  fi

  if docker compose version >/dev/null 2>&1; then
    ok "docker compose v2 installed"
    return 0
  fi

  warn "failed to install docker compose v2 automatically"
  tail -n 20 /tmp/remnanode-compose-install.log 2>/dev/null || true
  return 1
}

write_remnanode_files() {
  local secret_key="$1"
  local escaped_secret=""

  mkdir -p "$REMNANODE_DIR" "$CERT_DIR"
  chmod 700 "$CERT_DIR" || true

  backup_if_exists "$COMPOSE_FILE"
  escaped_secret="${secret_key//\\/\\\\}"
  escaped_secret="${escaped_secret//\"/\\\"}"

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

start_remnanode() {
  info "starting remnanode"
  (
    cd "$REMNANODE_DIR"
    docker compose up -d
    docker compose ps "$REMNANODE_SERVICE_NAME"
  )
}

set_sysctl_setting() {
  local key="$1"
  local value="$2"
  local conf_file="/etc/sysctl.conf"
  local escaped

  escaped="$(printf '%s' "$key" | sed -e 's/[.[\\*^$()+?{}|]/\\\\&/g')"

  if grep -Eq "^[[:space:]]*${escaped}[[:space:]]*=" "$conf_file"; then
    sed -i -E "s|^[[:space:]]*${escaped}[[:space:]]*=.*|${key}=${value}|" "$conf_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$conf_file"
  fi
}

configure_bbr() {
  set_sysctl_setting "net.core.default_qdisc" "fq"
  set_sysctl_setting "net.ipv4.tcp_congestion_control" "bbr"

  sysctl -p >/tmp/remnanode-sysctl.log 2>&1 || {
    cat /tmp/remnanode-sysctl.log >&2 || true
    return 1
  }

  local current_cc=""
  local current_qdisc=""
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  [[ "$current_cc" == "bbr" ]] || return 1
  [[ "$current_qdisc" == "fq" ]] || return 1

  ok "BBR enabled: tcp_congestion_control=$current_cc, default_qdisc=$current_qdisc"
}

install_traffic_guard() {
  export DEBIAN_FRONTEND=noninteractive

  wait_for_apt_locks 900

  if command -v debconf-set-selections >/dev/null 2>&1; then
    echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections || true
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections || true
  fi

  wait_for_apt_locks 900
  apt-get update -y
  wait_for_apt_locks 900
  apt-get install -y curl ipset iptables iptables-persistent rsyslog cron

  curl -fsSL https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh | bash
  [[ -x /usr/local/bin/traffic-guard ]] || die "traffic-guard binary not found at /usr/local/bin/traffic-guard"

  cat > /usr/local/sbin/traffic-guard-apply.sh <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/traffic-guard full \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/main/public/antiscanner.list \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/main/public/government_networks.list

netfilter-persistent save || true
EOF2

  chmod 755 /usr/local/sbin/traffic-guard-apply.sh
  local apply_attempt=1
  local max_attempts=5
  while (( apply_attempt <= max_attempts )); do
    wait_for_apt_locks 900
    if /usr/local/sbin/traffic-guard-apply.sh; then
      break
    fi
    if (( apply_attempt == max_attempts )); then
      die "traffic-guard apply failed after ${max_attempts} attempts"
    fi
    warn "traffic-guard apply failed (attempt ${apply_attempt}/${max_attempts}), retrying in 10s..."
    sleep 10
    apply_attempt=$((apply_attempt + 1))
  done

  cat > /etc/cron.d/traffic-guard-update <<'EOF2'
17 3 * * * root /usr/local/sbin/traffic-guard-apply.sh >> /var/log/traffic-guard-update.log 2>&1
EOF2

  chmod 644 /etc/cron.d/traffic-guard-update
  systemctl enable --now cron

  ok "traffic-guard installed and cron enabled (daily at 03:17)"
}

configure_ufw_smtp_protection() {
  local ssh_port="22"
  local ufw_out=""

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ssh_port="$(printf '%s' "$SSH_CONNECTION" | awk '{print $4}')"
  fi
  if ! is_int "$ssh_port"; then
    ssh_port="22"
  fi

  wait_for_apt_locks 900
  apt-get update -y
  wait_for_apt_locks 900
  apt-get install -y ufw

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow "${DEFAULT_NODE_PORT}/tcp"
  ufw allow 48765/tcp
  if [[ "$ssh_port" != "22" ]]; then
    ufw allow "${ssh_port}/tcp"
    ok "added current SSH server port rule: ${ssh_port}/tcp"
  fi
  ufw allow 443/tcp

  ufw deny out 25/tcp || true
  ufw route deny proto tcp to any port 25 || true

  ufw --force enable
  ufw reload

  ufw_out="$(ufw status verbose || true)"
  printf '%s\n' "$ufw_out" > /tmp/remnanode-ufw-status.log

  echo "$ufw_out" | grep -q "Default: deny (incoming), allow (outgoing)" || return 1
  echo "$ufw_out" | grep -Eq "22/tcp|OpenSSH" || return 1
  echo "$ufw_out" | grep -q "443/tcp" || return 1
  echo "$ufw_out" | grep -qE "25/tcp[[:space:]]+DENY OUT" || return 1
  echo "$ufw_out" | grep -qE "25/tcp[[:space:]]+DENY FWD" || return 1

  ok "ufw baseline + smtp protections applied"
}

extract_inline_certs_from_active_config() {
  local helper_tag="$CERT_HELPER_TAG"
  local log_file="/tmp/remnanode-inline-cert-sync.log"
  local container_ssl_dir="/var/lib/remnawave/configs/xray/ssl"

  if ! docker ps --format '{{.Names}}' | grep -qx "$REMNANODE_SERVICE_NAME"; then
    warn "container ${REMNANODE_SERVICE_NAME} is not running yet"
    return 1
  fi

  if docker exec -i \
    -e CERT_TAG="$helper_tag" \
    -e CERT_TAG_STRICT="$CERT_HELPER_TAG_STRICT" \
    "$REMNANODE_SERVICE_NAME" sh >"$log_file" 2>&1 <<'EOSH'
set -eu

SOCK="$(tr '\0' '\n' </proc/1/environ | sed -n 's/^INTERNAL_SOCKET_PATH=//p' | head -n1)"
TOK="$(tr '\0' '\n' </proc/1/environ | sed -n 's/^INTERNAL_REST_TOKEN=//p' | head -n1)"
[ -n "$SOCK" ] && [ -n "$TOK" ] || { echo "NO_RUNTIME_ENV"; exit 11; }

SOCK="$SOCK" TOK="$TOK" CERT_TAG="${CERT_TAG:-}" node <<'NODE'
const fs = require('fs');
const http = require('http');

const socketPath = process.env.SOCK;
const token = process.env.TOK;
const certTag = (process.env.CERT_TAG || '').trim();
const certTagStrict = (process.env.CERT_TAG_STRICT || '').trim() === '1';
const outDir = '/var/lib/remnawave/configs/xray/ssl';

function fail(msg, code) {
  console.error(msg);
  process.exit(code);
}

function getCertObj(ib) {
  return ib?.streamSettings?.tlsSettings?.certificates?.[0] || null;
}

function hasInlineCert(ib) {
  const c = getCertObj(ib);
  return Array.isArray(c?.certificate) &&
    c.certificate.length > 0 &&
    Array.isArray(c?.key) &&
    c.key.length > 0;
}

function hasFileRefCert(ib) {
  const c = getCertObj(ib);
  return typeof c?.certificateFile === 'string' &&
    c.certificateFile.trim().length > 0 &&
    typeof c?.keyFile === 'string' &&
    c.keyFile.trim().length > 0;
}

function isApiInbound(ib) {
  const tag = String(ib?.tag || '').toUpperCase();
  return tag === 'REMNAWAVE_API_INBOUND' || tag.includes('API_INBOUND');
}

http.get({ socketPath, path: `/internal/get-config?token=${token}` }, (res) => {
  let raw = '';
  res.on('data', (chunk) => {
    raw += chunk;
  });
  res.on('end', () => {
    let cfg;
    try {
      cfg = JSON.parse(raw || '{}');
    } catch {
      fail('BAD_CONFIG_JSON', 12);
    }

    const inbounds = Array.isArray(cfg?.inbounds) ? cfg.inbounds : [];

    const fileRefInbounds = inbounds.filter((ib) => hasFileRefCert(ib));
    const inlineInbounds = inbounds.filter((ib) => hasInlineCert(ib));
    if (fileRefInbounds.length === 0 && inlineInbounds.length === 0) {
      fail('NO_CERTS_IN_ACTIVE_CONFIG', 13);
    }

    let inbound = null;
    if (certTag) {
      inbound = fileRefInbounds.find((ib) => ib?.tag === certTag) ||
        inlineInbounds.find((ib) => ib?.tag === certTag) ||
        null;
      if (!inbound && certTagStrict) {
        const fileTags = fileRefInbounds.map((ib) => ib?.tag || '<no-tag>');
        const inlineTags = inlineInbounds.map((ib) => ib?.tag || '<no-tag>');
        fail(`NO_CERTS_FOR_TAG:${certTag};FILE_TAGS:${fileTags.join(',')};INLINE_TAGS:${inlineTags.join(',')}`, 13);
      }
    }
    if (!inbound) {
      const preferredFileRefs = fileRefInbounds.filter((ib) => !isApiInbound(ib));
      const preferredInline = inlineInbounds.filter((ib) => !isApiInbound(ib));
      inbound = preferredFileRefs[0] || preferredInline[0] || fileRefInbounds[0] || inlineInbounds[0];
    }

    const certObj = getCertObj(inbound);
    if (!certObj) {
      fail(`NO_CERT_OBJ_FOR_TAG:${inbound?.tag || '<no-tag>'}`, 14);
    }

    let certPem = '';
    let keyPem = '';
    let source = '';

    if (hasFileRefCert(inbound)) {
      source = 'file_refs';
      const certFile = certObj.certificateFile.trim();
      const keyFile = certObj.keyFile.trim();
      try {
        certPem = fs.readFileSync(certFile, 'utf8');
        keyPem = fs.readFileSync(keyFile, 'utf8');
      } catch (err) {
        fail(`CERT_FILE_READ_ERROR:${err.message};CERT_FILE:${certFile};KEY_FILE:${keyFile}`, 15);
      }
      if (!certPem.trim() || !keyPem.trim()) {
        fail(`CERT_FILE_EMPTY;CERT_FILE:${certFile};KEY_FILE:${keyFile}`, 16);
      }
      if (!certPem.endsWith('\n')) certPem += '\n';
      if (!keyPem.endsWith('\n')) keyPem += '\n';
    } else if (hasInlineCert(inbound)) {
      source = 'inline_pem';
      certPem = `${certObj.certificate.join('\n')}\n`;
      keyPem = `${certObj.key.join('\n')}\n`;
    } else {
      fail(`NO_USABLE_CERT_DATA_FOR_TAG:${inbound?.tag || '<no-tag>'}`, 17);
    }

    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(`${outDir}/fullchain.pem`, certPem, { mode: 0o644 });
    fs.writeFileSync(`${outDir}/privkey.pem`, keyPem, { mode: 0o600 });

    try { fs.unlinkSync(`${outDir}/privkey.key`); } catch {}
    try {
      fs.symlinkSync(`${outDir}/privkey.pem`, `${outDir}/privkey.key`);
    } catch {
      fs.writeFileSync(`${outDir}/privkey.key`, keyPem, { mode: 0o600 });
    }

    const fileTags = fileRefInbounds.map((ib) => ib?.tag || '<no-tag>');
    const inlineTags = inlineInbounds.map((ib) => ib?.tag || '<no-tag>');
    console.log(`EXTRACTED_FROM_TAG=${inbound.tag || '<no-tag>'};SOURCE=${source};FILE_TAGS=${fileTags.join(',')};INLINE_TAGS=${inlineTags.join(',')}`);
  });
}).on('error', (err) => {
  fail(`REQUEST_ERROR:${err.message}`, 14);
});
NODE
EOSH
  then
    mkdir -p "$CERT_DIR"

    if ! docker cp "${REMNANODE_SERVICE_NAME}:${container_ssl_dir}/fullchain.pem" "$DEFAULT_CERT_FILE" 2>/dev/null; then
      warn "runtime cert sync: failed to copy fullchain.pem from container"
      return 1
    fi

    if ! docker cp "${REMNANODE_SERVICE_NAME}:${container_ssl_dir}/privkey.pem" "$DEFAULT_KEY_PEM" 2>/dev/null; then
      warn "runtime cert sync: failed to copy privkey.pem from container"
      return 1
    fi

    chmod 644 "$DEFAULT_CERT_FILE" 2>/dev/null || true
    chmod 600 "$DEFAULT_KEY_PEM" 2>/dev/null || true
    ln -sfn "$DEFAULT_KEY_PEM" "$DEFAULT_KEY_KEY" || true

    if [[ -s "$DEFAULT_CERT_FILE" && ( -s "$DEFAULT_KEY_PEM" || -s "$DEFAULT_KEY_KEY" ) ]]; then
      ok "runtime certificates synced into ${CERT_DIR}"
      return 0
    fi

    warn "runtime cert sync: host certificate files are still missing in ${CERT_DIR}"
    return 1
  fi

  warn "runtime cert sync failed ($(tail -n 1 "$log_file" 2>/dev/null || echo unknown))"
  return 1
}

wait_for_node_certificates() {
  local cert_file="$DEFAULT_CERT_FILE"
  local key_file="$DEFAULT_KEY_PEM"
  local waited=0

  mkdir -p "$CERT_DIR"

  if [[ -s "$DEFAULT_KEY_PEM" && ! -e "$DEFAULT_KEY_KEY" ]]; then
    ln -sfn "$DEFAULT_KEY_PEM" "$DEFAULT_KEY_KEY" || true
  fi

  if [[ -s "$DEFAULT_KEY_KEY" ]]; then
    key_file="$DEFAULT_KEY_KEY"
  fi

  while [[ $waited -lt $CERT_WAIT_SECONDS ]]; do
    if [[ -s "$cert_file" && -s "$key_file" ]]; then
      ok "certificates detected in $CERT_DIR"
      return 0
    fi

    if (( waited % 10 == 0 )); then
      extract_inline_certs_from_active_config || true
      if [[ -s "$cert_file" && -s "$key_file" ]]; then
        ok "certificates extracted from active node config"
        return 0
      fi
    fi

    if [[ $waited -eq 0 ]]; then
      warn "certificates are not present yet"
      echo "Do this in panel now:"
      echo "1) Nodes -> Management -> open your node and finish creation"
      echo "2) Push/apply profile and restart Xray on node"
      echo "3) Ensure at least one Active Inbound has tlsSettings.certificates with certificateFile/keyFile paths"
      if [[ -n "$CERT_HELPER_TAG" ]]; then
        echo "4) Preferred cert tag is '${CERT_HELPER_TAG}' (set CERT_HELPER_TAG= to auto-pick first available cert source)"
      fi
      echo
      echo "Waiting up to ${CERT_WAIT_SECONDS}s for certs in $CERT_DIR ..."
    fi

    sleep 5
    waited=$((waited + 5))
    if [[ -s "$DEFAULT_KEY_KEY" ]]; then
      key_file="$DEFAULT_KEY_KEY"
    fi
  done

  warn "certificates were not detected automatically"
  return 1
}

pick_key_file() {
  if [[ -s "$DEFAULT_KEY_KEY" ]]; then
    printf '%s' "$DEFAULT_KEY_KEY"
    return 0
  fi
  if [[ -s "$DEFAULT_KEY_PEM" ]]; then
    printf '%s' "$DEFAULT_KEY_PEM"
    return 0
  fi
  return 1
}

hostname_matches_pattern() {
  local host="${1,,}"
  local pattern="${2,,}"
  local suffix=""
  local prefix=""

  if [[ -z "$host" || -z "$pattern" ]]; then
    return 1
  fi

  if [[ "$host" == "$pattern" ]]; then
    return 0
  fi

  if [[ "$pattern" == \*.* ]]; then
    suffix="${pattern#*.}"
    if [[ "$host" == *".${suffix}" ]]; then
      prefix="${host%.${suffix}}"
      [[ "$prefix" != *.* ]] && return 0
    fi
  fi

  return 1
}

cert_matches_domain() {
  local cert_file="$1"
  local domain="$2"
  local san_raw=""
  local san_entries=""
  local dns_name=""
  local cn=""

  [[ -s "$cert_file" ]] || return 1

  san_raw="$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null || true)"
  san_entries="$(printf '%s\n' "$san_raw" | grep -oE 'DNS:[^, ]+' | sed 's/^DNS://')"
  if [[ -n "$san_entries" ]]; then
    while IFS= read -r dns_name; do
      dns_name="$(trim "$dns_name")"
      if hostname_matches_pattern "$domain" "$dns_name"; then
        return 0
      fi
    done <<< "$san_entries"
    return 1
  fi

  cn="$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*//p' | head -n1)"
  cn="$(trim "$cn")"
  hostname_matches_pattern "$domain" "$cn"
}

show_cert_brief() {
  local cert_file="$1"
  openssl x509 -in "$cert_file" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || true
}

cert_contains_dns_pattern() {
  local cert_file="$1"
  local required_pattern="${2,,}"
  local san_raw=""
  local san_entries=""
  local dns_name=""
  local cn=""

  [[ -s "$cert_file" ]] || return 1
  [[ -n "$required_pattern" ]] || return 0

  san_raw="$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null || true)"
  san_entries="$(printf '%s\n' "$san_raw" | grep -oE 'DNS:[^, ]+' | sed 's/^DNS://')"
  if [[ -n "$san_entries" ]]; then
    while IFS= read -r dns_name; do
      dns_name="$(trim "$dns_name")"
      [[ "${dns_name,,}" == "$required_pattern" ]] && return 0
    done <<< "$san_entries"
  fi

  cn="$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*//p' | head -n1)"
  cn="$(trim "$cn")"
  [[ "${cn,,}" == "$required_pattern" ]]
}

install_selfsteal_cert_sync() {
  local sync_script="/usr/local/bin/remnanode-selfsteal-cert-sync"
  local service_file="/etc/systemd/system/remnanode-selfsteal-cert-sync.service"
  local timer_file="/etc/systemd/system/remnanode-selfsteal-cert-sync.timer"

  if [[ "${CERT_SYNC_ENABLED:-1}" != "1" ]]; then
    warn "selfsteal cert sync is disabled (CERT_SYNC_ENABLED=${CERT_SYNC_ENABLED})"
    return 0
  fi

  cat > "$sync_script" <<'SYNC_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

REMNANODE_SERVICE_NAME="${REMNANODE_SERVICE_NAME:-__REMNANODE_SERVICE_NAME__}"
SELFSTEAL_NGINX_SERVICE_NAME="${SELFSTEAL_NGINX_SERVICE_NAME:-__SELFSTEAL_NGINX_SERVICE_NAME__}"
SELFSTEAL_BASE_DOMAIN="${SELFSTEAL_BASE_DOMAIN:-__SELFSTEAL_BASE_DOMAIN__}"
CERT_HELPER_TAG="${CERT_HELPER_TAG:-__CERT_HELPER_TAG__}"
CERT_HELPER_TAG_STRICT="${CERT_HELPER_TAG_STRICT:-__CERT_HELPER_TAG_STRICT__}"
REMNANODE_CERT_DIR="${REMNANODE_CERT_DIR:-__REMNANODE_CERT_DIR__}"
SELFSTEAL_NGINX_SSL_DIR="${SELFSTEAL_NGINX_SSL_DIR:-__SELFSTEAL_NGINX_SSL_DIR__}"
LOCK_FILE="\${LOCK_FILE:-/run/remnanode-selfsteal-cert-sync.lock}"

log() { echo "[cert-sync] \$*"; }
warn() { echo "[cert-sync] WARN: \$*" >&2; }
die() { echo "[cert-sync] FAIL: \$*" >&2; exit 1; }

fingerprint() {
  local cert_file="\$1"
  [[ -s "\$cert_file" ]] || return 1
  openssl x509 -in "\$cert_file" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"
command -v flock >/dev/null 2>&1 || die "flock is required"

exec 9>"\$LOCK_FILE"
flock -n 9 || { log "another sync is running"; exit 0; }

tmp_dir="\$(mktemp -d)"
trap 'rm -rf "\$tmp_dir"' EXIT

docker ps --format '{{.Names}}' | grep -qx "\$REMNANODE_SERVICE_NAME" || die "container \$REMNANODE_SERVICE_NAME is not running"

docker exec -i \
  -e BASE_DOMAIN="\$SELFSTEAL_BASE_DOMAIN" \
  -e CERT_TAG="\$CERT_HELPER_TAG" \
  -e CERT_TAG_STRICT="\$CERT_HELPER_TAG_STRICT" \
  "\$REMNANODE_SERVICE_NAME" sh <<'EOSH'
set -eu

SOCK="$(tr '\0' '\n' </proc/1/environ | sed -n 's/^INTERNAL_SOCKET_PATH=//p' | head -n1)"
TOK="$(tr '\0' '\n' </proc/1/environ | sed -n 's/^INTERNAL_REST_TOKEN=//p' | head -n1)"
[ -n "$SOCK" ] && [ -n "$TOK" ] || { echo "NO_RUNTIME_ENV" >&2; exit 11; }

SOCK="$SOCK" TOK="$TOK" BASE_DOMAIN="${BASE_DOMAIN:-}" CERT_TAG="${CERT_TAG:-}" CERT_TAG_STRICT="${CERT_TAG_STRICT:-0}" node <<'NODE'
const fs = require('fs');
const http = require('http');

const socketPath = process.env.SOCK;
const token = process.env.TOK;
const baseDomain = (process.env.BASE_DOMAIN || '').trim().toLowerCase().replace(/^\./, '');
const certTag = (process.env.CERT_TAG || '').trim();
const certTagStrict = (process.env.CERT_TAG_STRICT || '').trim() === '1';

function fail(message, code) {
  console.error(message);
  process.exit(code);
}

function getCertObj(ib) {
  return ib?.streamSettings?.tlsSettings?.certificates?.[0] || null;
}

function hasInlineCert(ib) {
  const c = getCertObj(ib);
  return Array.isArray(c?.certificate) && c.certificate.length > 0 &&
    Array.isArray(c?.key) && c.key.length > 0;
}

function hasFileRefCert(ib) {
  const c = getCertObj(ib);
  return typeof c?.certificateFile === 'string' && c.certificateFile.trim().length > 0 &&
    typeof c?.keyFile === 'string' && c.keyFile.trim().length > 0;
}

function isApiInbound(ib) {
  const tag = String(ib?.tag || '').toUpperCase();
  return tag === 'REMNAWAVE_API_INBOUND' || tag.includes('API_INBOUND');
}

function baseDomainMatch(name) {
  const lower = String(name || '').trim().toLowerCase();
  return baseDomain && (lower === baseDomain || lower.endsWith(`.${baseDomain}`));
}

function scoreInbound(ib, order) {
  if (!hasInlineCert(ib) && !hasFileRefCert(ib)) return -1;
  if (isApiInbound(ib)) return -1;
  if (certTagStrict && certTag && ib?.tag !== certTag) return -1;

  const tag = String(ib?.tag || '').toLowerCase();
  const names = Array.isArray(ib?.streamSettings?.realitySettings?.serverNames)
    ? ib.streamSettings.realitySettings.serverNames
    : [];

  let score = 0;
  if (certTag && ib?.tag === certTag) score += 10000;
  if (tag.includes('selfsteal') || tag.includes('selfstealer')) score += 1000;
  if (Number(ib?.port) === 443) score += 500;
  if (names.some(baseDomainMatch)) score += 300;
  if (hasFileRefCert(ib)) score += 20;
  if (hasInlineCert(ib)) score += 10;
  return score * 100000 - order;
}

http.get({ socketPath, path: `/internal/get-config?token=${encodeURIComponent(token)}` }, (res) => {
  let raw = '';
  res.on('data', (chunk) => {
    raw += chunk;
  });
  res.on('end', () => {
    let cfg;
    try {
      cfg = JSON.parse(raw || '{}');
    } catch {
      fail(`BAD_CONFIG_JSON:${raw.slice(0, 80).replace(/\n/g, ' ')}`, 12);
    }

    const inbounds = Array.isArray(cfg?.inbounds) ? cfg.inbounds : [];
    const candidates = inbounds
      .map((ib, order) => ({ ib, score: scoreInbound(ib, order) }))
      .filter((candidate) => candidate.score >= 0)
      .sort((a, b) => b.score - a.score);

    if (candidates.length === 0) {
      fail('NO_SELFSTEAL_CERT_IN_ACTIVE_CONFIG', 13);
    }

    const inbound = candidates[0].ib;
    const certObj = getCertObj(inbound);
    let certPem = '';
    let keyPem = '';
    let source = '';

    if (hasFileRefCert(inbound)) {
      source = 'file_refs';
      const certFile = certObj.certificateFile.trim();
      const keyFile = certObj.keyFile.trim();
      try {
        certPem = fs.readFileSync(certFile, 'utf8');
        keyPem = fs.readFileSync(keyFile, 'utf8');
      } catch (err) {
        fail(`CERT_FILE_READ_ERROR:${err.message};CERT_FILE:${certFile};KEY_FILE:${keyFile}`, 14);
      }
    } else if (hasInlineCert(inbound)) {
      source = 'inline_pem';
      certPem = `${certObj.certificate.join('\n')}\n`;
      keyPem = `${certObj.key.join('\n')}\n`;
    } else {
      fail(`NO_USABLE_CERT_DATA_FOR_TAG:${inbound?.tag || '<no-tag>'}`, 15);
    }

    fs.writeFileSync('/tmp/remnanode-selfsteal-fullchain.pem', certPem.endsWith('\n') ? certPem : `${certPem}\n`, { mode: 0o644 });
    fs.writeFileSync('/tmp/remnanode-selfsteal-privkey.pem', keyPem.endsWith('\n') ? keyPem : `${keyPem}\n`, { mode: 0o600 });
    fs.writeFileSync('/tmp/remnanode-selfsteal-source.txt', `tag=${inbound?.tag || '<no-tag>'};source=${source}\n`, { mode: 0o644 });
  });
}).on('error', (err) => {
  fail(`REQUEST_ERROR:${err.message}`, 16);
});
NODE
EOSH

docker cp "\$REMNANODE_SERVICE_NAME:/tmp/remnanode-selfsteal-fullchain.pem" "\$tmp_dir/fullchain.pem" >/dev/null
docker cp "\$REMNANODE_SERVICE_NAME:/tmp/remnanode-selfsteal-privkey.pem" "\$tmp_dir/privkey.pem" >/dev/null
docker cp "\$REMNANODE_SERVICE_NAME:/tmp/remnanode-selfsteal-source.txt" "\$tmp_dir/source.txt" >/dev/null 2>&1 || true

incoming_fp="\$(fingerprint "\$tmp_dir/fullchain.pem")" || die "incoming certificate is invalid"
current_nginx_fp=""
current_remnanode_fp=""
if [[ -s "\$SELFSTEAL_NGINX_SSL_DIR/fullchain.crt" ]]; then
  current_nginx_fp="\$(fingerprint "\$SELFSTEAL_NGINX_SSL_DIR/fullchain.crt" || true)"
fi
if [[ -s "\$REMNANODE_CERT_DIR/fullchain.pem" ]]; then
  current_remnanode_fp="\$(fingerprint "\$REMNANODE_CERT_DIR/fullchain.pem" || true)"
fi

reload_nginx=0
if [[ "\$incoming_fp" != "\$current_nginx_fp" ]]; then
  reload_nginx=1
fi

if [[ -n "\$current_nginx_fp" && "\$incoming_fp" == "\$current_nginx_fp" && "\$incoming_fp" == "\$current_remnanode_fp" ]]; then
  log "certificate unchanged: \$incoming_fp"
  exit 0
fi

log "certificate sync needed: nginx=\${current_nginx_fp:-none}, remnanode=\${current_remnanode_fp:-none}, incoming=\$incoming_fp"
if [[ -s "\$tmp_dir/source.txt" ]]; then
  log "\$(cat "\$tmp_dir/source.txt")"
fi

stamp="\$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -d "\$SELFSTEAL_NGINX_SSL_DIR" ]]; then
  cp -a "\$SELFSTEAL_NGINX_SSL_DIR" "\$SELFSTEAL_NGINX_SSL_DIR.backup.\$stamp"
fi
if [[ -d "\$REMNANODE_CERT_DIR" ]]; then
  cp -a "\$REMNANODE_CERT_DIR" "\$REMNANODE_CERT_DIR.backup.\$stamp"
fi

mkdir -p "\$SELFSTEAL_NGINX_SSL_DIR" "\$REMNANODE_CERT_DIR"
install -m 0644 "\$tmp_dir/fullchain.pem" "\$SELFSTEAL_NGINX_SSL_DIR/fullchain.crt"
install -m 0600 "\$tmp_dir/privkey.pem" "\$SELFSTEAL_NGINX_SSL_DIR/private.key"
install -m 0644 "\$tmp_dir/fullchain.pem" "\$REMNANODE_CERT_DIR/fullchain.pem"
install -m 0600 "\$tmp_dir/privkey.pem" "\$REMNANODE_CERT_DIR/privkey.pem"
ln -sfn "\$REMNANODE_CERT_DIR/privkey.pem" "\$REMNANODE_CERT_DIR/privkey.key"

docker ps --format '{{.Names}}' | grep -qx "\$SELFSTEAL_NGINX_SERVICE_NAME" || die "container \$SELFSTEAL_NGINX_SERVICE_NAME is not running"
docker exec "\$SELFSTEAL_NGINX_SERVICE_NAME" nginx -t
if [[ "\$reload_nginx" == "1" ]]; then
  docker exec "\$SELFSTEAL_NGINX_SERVICE_NAME" nginx -s reload
  log "nginx reloaded with certificate: \$incoming_fp"
else
  log "nginx certificate already current; files synced without reload: \$incoming_fp"
fi
SYNC_SCRIPT

  local esc_remnanode_service=""
  local esc_selfsteal_service=""
  local esc_base_domain=""
  local esc_cert_helper_tag=""
  local esc_cert_helper_tag_strict=""
  local esc_cert_dir=""
  local esc_nginx_ssl_dir=""

  esc_remnanode_service="$(printf '%s' "$REMNANODE_SERVICE_NAME" | sed -e 's/[\\&|]/\\&/g')"
  esc_selfsteal_service="$(printf '%s' "$SELFSTEAL_NGINX_SERVICE_NAME" | sed -e 's/[\\&|]/\\&/g')"
  esc_base_domain="$(printf '%s' "$SELFSTEAL_BASE_DOMAIN" | sed -e 's/[\\&|]/\\&/g')"
  esc_cert_helper_tag="$(printf '%s' "$CERT_HELPER_TAG" | sed -e 's/[\\&|]/\\&/g')"
  esc_cert_helper_tag_strict="$(printf '%s' "$CERT_HELPER_TAG_STRICT" | sed -e 's/[\\&|]/\\&/g')"
  esc_cert_dir="$(printf '%s' "$CERT_DIR" | sed -e 's/[\\&|]/\\&/g')"
  esc_nginx_ssl_dir="$(printf '%s' "$SELFSTEAL_NGINX_SSL_DIR" | sed -e 's/[\\&|]/\\&/g')"

  sed -i \
    -e 's/\\\$/$/g' \
    -e "s|__REMNANODE_SERVICE_NAME__|$esc_remnanode_service|g" \
    -e "s|__SELFSTEAL_NGINX_SERVICE_NAME__|$esc_selfsteal_service|g" \
    -e "s|__SELFSTEAL_BASE_DOMAIN__|$esc_base_domain|g" \
    -e "s|__CERT_HELPER_TAG__|$esc_cert_helper_tag|g" \
    -e "s|__CERT_HELPER_TAG_STRICT__|$esc_cert_helper_tag_strict|g" \
    -e "s|__REMNANODE_CERT_DIR__|$esc_cert_dir|g" \
    -e "s|__SELFSTEAL_NGINX_SSL_DIR__|$esc_nginx_ssl_dir|g" \
    "$sync_script"

  chmod 0755 "$sync_script"

  cat > "$service_file" <<EOF2
[Unit]
Description=Sync selfsteal TLS certificate from RemnaNode active config
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$sync_script
EOF2

  cat > "$timer_file" <<EOF2
[Unit]
Description=Daily selfsteal TLS certificate sync

[Timer]
OnCalendar=${CERT_SYNC_ON_CALENDAR}
RandomizedDelaySec=${CERT_SYNC_RANDOMIZED_DELAY_SECONDS}
Persistent=true

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
  if [[ "${CERT_SYNC_TIMER_ENABLED:-1}" == "1" ]]; then
    systemctl enable --now remnanode-selfsteal-cert-sync.timer
    ok "selfsteal cert sync timer enabled: ${CERT_SYNC_ON_CALENDAR} (+${CERT_SYNC_RANDOMIZED_DELAY_SECONDS}s random delay)"
  else
    systemctl disable --now remnanode-selfsteal-cert-sync.timer >/dev/null 2>&1 || true
    ok "selfsteal cert sync script installed: $sync_script"
  fi

  if "$sync_script"; then
    ok "selfsteal cert sync initial run completed"
  else
    warn "selfsteal cert sync initial run failed; check journalctl -u remnanode-selfsteal-cert-sync.service"
  fi
}

install_selfsteal() {
  local domain="${SELFSTEAL_DOMAIN:-}"
  local template="${SELFSTEAL_TEMPLATE:-}"
  local port="${SELFSTEAL_PORT:-}"
  local cert="${SELFSTEAL_SSL_CERT:-$DEFAULT_CERT_FILE}"
  local key="${SELFSTEAL_SSL_KEY:-}"
  local installer_file=""
  local installer_log=""
  local detected_domain=""
  local prompt_value=""

  domain="$(trim "$domain")"
  template="$(trim "$template")"
  port="$(trim "$port")"

  if [[ -z "$domain" ]]; then
    detected_domain="$(detect_selfsteal_domain_from_active_config || true)"
    if [[ -n "$detected_domain" ]]; then
      prompt_value="$(selfsteal_domain_prompt_value "$detected_domain")"
      prompt_default domain "Detected serverName ${detected_domain}. Selfsteal subdomain/domain [${prompt_value}]: " "$prompt_value"
    else
      prompt_default domain "Selfsteal subdomain for ${SELFSTEAL_BASE_DOMAIN} [${DEFAULT_SELFSTEAL_SUBDOMAIN}]: " "$DEFAULT_SELFSTEAL_SUBDOMAIN"
    fi
  fi
  domain="$(normalize_selfsteal_domain "$domain")"
  [[ -n "$domain" ]] || die "domain is required"

  if [[ -z "$template" ]]; then
    prompt_default template "Selfsteal template 1-11 [${DEFAULT_SELFSTEAL_TEMPLATE}]: " "$DEFAULT_SELFSTEAL_TEMPLATE"
  fi
  is_int_1_11 "$template" || die "template must be 1..11 (got: $template)"

  if [[ -z "$port" ]]; then
    port="$DEFAULT_SELFSTEAL_PORT"
  fi
  is_int "$port" || die "port must be numeric (got: $port)"

  if [[ -z "$key" ]]; then
    key="$(pick_key_file || true)"
  fi
  [[ -n "$key" ]] || die "key file not found in $CERT_DIR"

  [[ -s "$cert" ]] || die "certificate file not found or empty: $cert"
  [[ -s "$key" ]] || die "key file not found or empty: $key"

  if ! cert_matches_domain "$cert" "$domain"; then
    warn "certificate in $cert does not match domain ${domain}; trying runtime re-sync once"
    if [[ "$cert" == "$DEFAULT_CERT_FILE" ]]; then
      extract_inline_certs_from_active_config || true
      [[ -z "${SELFSTEAL_SSL_KEY:-}" ]] && key="$(pick_key_file || true)"
    fi
    if ! cert_matches_domain "$cert" "$domain"; then
      echo "Current certificate details:"
      show_cert_brief "$cert"
      die "certificate does not cover ${domain}; update node certificate in panel and push profile"
    fi
    ok "certificate now matches ${domain}"
  fi

  if ! cert_contains_dns_pattern "$cert" "$CERT_REQUIRED_DNS_PATTERN"; then
    echo "Current certificate details:"
    show_cert_brief "$cert"
    die "certificate must contain DNS name '${CERT_REQUIRED_DNS_PATTERN}'"
  fi

  chmod 600 "$key" 2>/dev/null || true

  info "installing selfsteal with certs from remnanode mount"
  echo "  cert: $cert"
  echo "  key:  $key"
  echo "  domain: $domain"
  echo "  template: $template"
  echo "  port: 127.0.0.1:${port}"

  installer_file="$(mktemp /tmp/selfsteal-installer.XXXXXX.sh)"
  installer_log="$(mktemp /tmp/selfsteal-install.XXXXXX.log)"
  curl -fsSL "$SELFSTEAL_SCRIPT_URL" -o "$installer_file" || die "failed to download selfsteal installer from $SELFSTEAL_SCRIPT_URL"

  if ! bash "$installer_file" @ \
    --nginx --tcp --force \
    --domain "$domain" \
    --port "$port" \
    --ssl-cert "$cert" \
    --ssl-key "$key" \
    --template "$template" \
    install > >(tee "$installer_log") 2>&1; then
    rm -f "$installer_file"
    die "selfsteal installer failed (log: $installer_log)"
  fi
  rm -f "$installer_file"

  if grep -Eq "System requirements not met|Docker Compose V2 is still not available" "$installer_log"; then
    die "selfsteal installer reported unmet requirements (log: $installer_log)"
  fi

  local l9443=""
  local wait_listen_seconds=30
  local waited=0
  while (( waited < wait_listen_seconds )); do
    l9443="$(ss -H -ltnp "( sport = :${port} )" 2>/dev/null || true)"
    if echo "$l9443" | grep -Eq 'nginx|docker-proxy'; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if ! echo "$l9443" | grep -Eq 'nginx|docker-proxy'; then
    selfsteal status >/tmp/selfsteal-status-after-install.log 2>&1 || true
    die "selfsteal endpoint 127.0.0.1:${port} is not listening after install (status: /tmp/selfsteal-status-after-install.log, installer log: $installer_log)"
  fi

  ok "selfsteal installed"

  local l443=""
  l443="$(ss -H -ltnp '( sport = :443 )' 2>/dev/null || true)"
  if echo "$l443" | grep -q 'rw-core'; then
    ok "port 443 is owned by rw-core"
  else
    warn "port 443 is not owned by rw-core; check remnanode/rw-core status"
  fi

  local code=""
  code="$(curl -skI "https://${domain}/" --resolve "${domain}:443:127.0.0.1" --max-time 5 | awk 'NR==1{print $2; exit}' || true)"
  if [[ "$code" == "200" ]]; then
    ok "fallback via 443 returns HTTP 200"
  else
    warn "fallback via 443 returned HTTP ${code:-none}"
  fi

  echo
  echo "Use these values in panel Xray profile:"
  echo "  realitySettings.dest: \"127.0.0.1:${port}\""
  echo "  realitySettings.xver: 1"
  echo "  realitySettings.serverNames: [\"${domain}\"]"
  echo "  settings.fallbacks: [{\"dest\":\"127.0.0.1:${port}\",\"xver\":1}]"
  echo "  certificates[0].certificateFile: \"/var/lib/remnawave/configs/xray/ssl/fullchain.pem\""
  echo "  certificates[0].keyFile: \"/var/lib/remnawave/configs/xray/ssl/privkey.key\" (or privkey.pem)"
}

main() {
  require_root
  select_install_mode
  mark_skipped_steps

  need_cmd awk
  need_cmd sed
  need_cmd grep

  if [[ "$RUN_NODE" -eq 1 || "$RUN_SELFSTEAL" -eq 1 || "$RUN_SCANNER" -eq 1 ]]; then
    need_cmd curl
  fi
  if [[ "$RUN_SELFSTEAL" -eq 1 ]]; then
    need_cmd ss
  fi

  if [[ "$RUN_NODE" -eq 1 ]]; then
    STATUS_NODE="IN_PROGRESS"
    install_docker_if_needed

    local secret_key="${REMNANODE_SECRET_KEY:-}"
    secret_key="$(printf '%s' "$secret_key" | tr -d '\r\n')"
    secret_key="$(trim "$secret_key")"
    if [[ -z "$secret_key" ]]; then
      prompt_default secret_key "Paste SECRET_KEY from panel: " ""
      secret_key="$(printf '%s' "$secret_key" | tr -d '\r\n')"
      secret_key="$(trim "$secret_key")"
    fi
    [[ -n "$secret_key" ]] || die "SECRET_KEY is required"

    write_remnanode_files "$secret_key"
    start_remnanode
    STATUS_NODE="OK"
    NOTE_NODE="compose up completed"
  fi

  if [[ "$RUN_OPTIMIZATION" -eq 1 ]]; then
    STATUS_OPTIMIZATION="IN_PROGRESS"
    if configure_bbr; then
      STATUS_OPTIMIZATION="OK"
      NOTE_OPTIMIZATION="BBR enabled"
    else
      STATUS_OPTIMIZATION="FAIL"
      NOTE_OPTIMIZATION="BBR configuration failed"
      warn "BBR configuration failed"
    fi
  fi

  if [[ "$RUN_SCANNER" -eq 1 ]]; then
    STATUS_SCANNER="IN_PROGRESS"
    if configure_ufw_smtp_protection && install_traffic_guard; then
      STATUS_SCANNER="OK"
      NOTE_SCANNER="ufw + traffic-guard active"
    else
      STATUS_SCANNER="FAIL"
      NOTE_SCANNER="ufw/traffic-guard setup failed"
      warn "ufw or traffic-guard setup failed"
    fi
  fi

  if [[ "$RUN_SELFSTEAL" -eq 1 ]]; then
    need_cmd docker
    ensure_docker_compose_v2 || die "docker compose v2 is required for selfsteal install"

    if [[ "$RUN_NODE" -eq 0 ]]; then
      if ! docker ps --format '{{.Names}}' | grep -qx "$REMNANODE_SERVICE_NAME"; then
        warn "container ${REMNANODE_SERVICE_NAME} is not running; cert extraction from runtime config may fail"
      fi
    fi

    STATUS_SELFSTEAL="IN_PROGRESS"
    if ! wait_for_node_certificates; then
      STATUS_SELFSTEAL="FAIL"
      NOTE_SELFSTEAL="certificates not received from panel yet"
      warn "continue with selfsteal only after certs appear in $CERT_DIR"
      echo "Re-run this script later with:"
      echo "  REMNANODE_DIR=$REMNANODE_DIR SELFSTEAL_DOMAIN=<subdomain-or-domain> bash $0"
      exit 2
    fi

    if install_selfsteal; then
      install_selfsteal_cert_sync
      STATUS_SELFSTEAL="OK"
      NOTE_SELFSTEAL="installed, checked, cert sync timer enabled"
    else
      STATUS_SELFSTEAL="FAIL"
      NOTE_SELFSTEAL="installation failed"
      exit 2
    fi
  fi

  if [[ "$RUN_CERT_SYNC" -eq 1 ]]; then
    need_cmd docker
    STATUS_SELFSTEAL="IN_PROGRESS"
    if install_selfsteal_cert_sync; then
      STATUS_SELFSTEAL="OK"
      NOTE_SELFSTEAL="cert sync timer enabled"
    else
      STATUS_SELFSTEAL="FAIL"
      NOTE_SELFSTEAL="cert sync timer setup failed"
      exit 2
    fi
  fi

  echo
  ok "completed"
  if [[ "$RUN_NODE" -eq 1 ]]; then
    echo "Node compose: $COMPOSE_FILE"
  fi
  if [[ "$RUN_SELFSTEAL" -eq 1 || "$RUN_NODE" -eq 1 ]]; then
    echo "Node cert dir:$CERT_DIR"
  fi

  if [[ "$STATUS_OPTIMIZATION" == "FAIL" || "$STATUS_SCANNER" == "FAIL" ]]; then
    exit 3
  fi

  exit 0
}

main "$@"
