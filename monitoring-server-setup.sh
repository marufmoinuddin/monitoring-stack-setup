#!/usr/bin/env bash
# =============================================================================
# monitoring-server-setup.sh — VPS half of the Grafana + Prometheus +
# http-over-ssh monitoring stack.
#
# Run this ON THE VPS (your-vps). It is idempotent: safe to re-run.
# It produces client-bundle.env, which the client script consumes.
#
# Usage:
#   sudo ./monitoring-server-setup.sh --dry-run          # show everything, change nothing
#   sudo ./monitoring-server-setup.sh                    # do it (prompts before writing)
#   sudo ./monitoring-server-setup.sh --yes              # do it, no prompts
#   sudo ./monitoring-server-setup.sh --add-client-key "ssh-ed25519 AAAA... g14"
#
# Phase 2 (after the client has started its tunnel):
#   sudo ./monitoring-server-setup.sh --add-client-key "ssh-ed25519 AAAA... g14"
#     -> installs the tunnel key, waits for the tunnel, pins the client host key
#
# Rollback:  sudo ./monitoring-server-setup.sh --rollback
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------- defaults ---
SUBNET="172.30.0.0/24"
GATEWAY="172.30.0.1"
NET_NAME="monitoring_net"
PROXY_NET="proxy_net"
TUNNEL_PORTS=(2201 2202 2203)
DOMAIN="${DOMAIN:-monitor.example.com}"
GRAFANA_HOST="${GRAFANA_HOST:-grafana}"
RETENTION_TIME="${RETENTION_TIME:-90d}"
RETENTION_SIZE="${RETENTION_SIZE:-20GB}"
PROJECT="${PROJECT:-$HOME/docker/monitoring}"
SSHD_DROPIN="56-monitor-tunnel.conf"
PROXY_VERSION="5421b44fdf4f0529670308558b6bf7f54ce7e1cc"   # v0.3.7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
ASSUME_YES=0
ROLLBACK=0
CLIENT_KEY=""
SUDO=""
# WEB_MODE:
#   nginx  - publish Grafana through an existing nginx (container or native)
#   none   - no web server at all; Grafana stays on loopback, reach it with
#            an SSH tunnel. Nothing is exposed, which is the safest default.
WEB_MODE="${WEB_MODE:-nginx}"
NO_ADMIN=0
ADMIN_URL="${ADMIN_URL:-}"

# ------------------------------------------------------------------ helpers ---
c_ok()   { printf '\033[0;32m  ok\033[0m   %s\n' "$*"; }
c_warn() { printf '\033[0;33m  warn\033[0m %s\n' "$*"; }
c_err()  { printf '\033[0;31m  fail\033[0m %s\n' "$*" >&2; }
c_step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
c_note() { printf '       %s\n' "$*"; }

die() { c_err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------- add-client-key ---
# Phase 2: install the client's tunnel public key, then wait for its tunnel and
# pin its host key into the proxy's known_hosts.
add_client_key() {
  [ -n "$CLIENT_KEY" ] || die "--add-client-key needs a public key"
  case "$CLIENT_KEY" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
    *) die "that does not look like an SSH public key" ;;
  esac

  local port="${TUNNEL_PORTS[0]}"
  local line="restrict,port-forwarding,permitlisten=\"${GATEWAY}:${port}\" ${CLIENT_KEY}"

  c_step "Authorizing client tunnel key on port ${port}"
  echo "  will append:"; echo "    ${line}"
  confirm

  # Replace any previous entry for the same key COMMENT, so re-running is safe
  # and never leaves two lines for one device.
  local comment
  comment="$(printf '%s' "$CLIENT_KEY" | awk '{print $NF}')"

  # Build the new file with awk rather than a cat chain: it is atomic, cannot
  # lose the existing entries, and cannot half-write on failure.
  #
  # The read MUST use $SUDO. authorized_keys is mode 600 owned by monitor, so
  # a plain read as a non-root user silently yields nothing — which would look
  # like an empty file and cause us to overwrite the other devices' keys.
  local tmp; tmp="$(mktemp)"
  local before=0
  if [ -f /home/monitor/.ssh/authorized_keys ]; then
    before="$($SUDO grep -cve '^[[:space:]]*$' /home/monitor/.ssh/authorized_keys 2>/dev/null || echo ERR)"
    [ "$before" = "ERR" ] && die "cannot read /home/monitor/.ssh/authorized_keys — run with sudo"
    $SUDO awk -v c="$comment" 'index($0, c) == 0' /home/monitor/.ssh/authorized_keys > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\n' "$line" >> "$tmp"

  # Safety net: the result must contain every other device's line plus ours.
  # If it does not, refuse to continue rather than drop a device's access.
  local after; after="$(grep -cve '^[[:space:]]*$' "$tmp" || true)"
  if [ "$before" -gt 0 ] && [ "$after" -lt "$before" ]; then
    die "merge would drop entries (had $before, produced $after) — refusing to write"
  fi

  echo "  --- resulting authorized_keys ($after line(s), was $before) ---"
  sed 's/^/       /' "$tmp"
  confirm

  if [ "$DRY_RUN" -eq 0 ]; then
    sudo touch /home/monitor/.ssh/authorized_keys
    sudo install -m 600 -o monitor -g monitor "$tmp" /home/monitor/.ssh/authorized_keys
    rm -f "$tmp"
    c_ok "installed. fingerprint: $(sudo ssh-keygen -lf /home/monitor/.ssh/authorized_keys | tail -1)"
  else
    rm -f "$tmp"
  fi

  c_step "Waiting for the client tunnel on ${GATEWAY}:${port}"
  if [ "$DRY_RUN" -eq 1 ]; then
    c_note "[dry-run] would poll for the listener and pin host keys"
    return 0
  fi
  local ok=0
  for i in $(seq 1 30); do
    if nc -z -w 2 "$GATEWAY" "$port" 2>/dev/null; then ok=1; break; fi
    printf '       waiting... (%ds/%ds) — client must have its autossh running\n' "$((i*5))" 150
    sleep 5
  done
  [ "$ok" -eq 1 ] || { c_err "no tunnel after 150s — start the client tunnel first"; return 1; }
  c_ok "tunnel is listening"

  c_step "Pinning client host key(s) for the proxy"
  # ALL key types, not just ed25519: knownhosts rejects any unlisted type for a
  # host it already knows, which surfaces as "key mismatch".
  local scan="/tmp/mon_scan_$$"
  ssh-keyscan -p "$port" "$GATEWAY" 2>/dev/null | grep -v '^#' > "$scan" || true
  [ -s "$scan" ] || { c_err "ssh-keyscan returned nothing"; rm -f "$scan"; return 1; }
  c_ok "$(wc -l < "$scan") host key type(s) offered by the client:"
  ssh-keygen -lf "$scan" | sed 's/^/       /'

  # Show the operator what will be trusted, then require confirmation. This is
  # the point where a MITM would be visible, so we never auto-accept.
  echo
  echo "  Compare these against the CLIENT's own output:"
  echo "    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
  echo
  confirm

  local kh="$PROJECT/ssh/known_hosts"
  mkdir -p "$PROJECT/ssh"
  touch "$kh"
  grep -v "^\[${GATEWAY}\]:${port}[[:space:]]" "$kh" > /tmp/mon_kh.new || true
  cat /tmp/mon_kh.new "$scan" > /tmp/mon_kh2.new
  install -m 644 /tmp/mon_kh2.new "$kh"
  rm -f "$scan" /tmp/mon_kh.new /tmp/mon_kh2.new
  c_ok "known_hosts updated:"
  ssh-keygen -lf "$kh" | sed 's/^/       /'

  c_step "Restarting proxy to load the new known_hosts"
  ( cd "$PROJECT" && docker compose up -d --force-recreate http-over-ssh )
  sleep 3
  docker logs --tail 6 http-over-ssh 2>&1 | sed 's/^/       /'
  c_note "look for: SSH connection to promssh@ established"
  echo
  c_ok "done — check Grafana, or:"
  echo "    cd $PROJECT && docker compose exec prometheus \\"
  echo "      wget -qO- 'http://localhost:9090/api/v1/query?query=up'"
}

# ------------------------------------------------------------------ rollback ---
rollback() {
  c_step "Rollback"
  echo "  This will:"
  echo "    - stop and REMOVE the monitoring containers (volumes kept by default)"
  echo "    - delete /etc/ssh/sshd_config.d/$SSHD_DROPIN"
  echo "    - delete the UFW rules for ${SUBNET%/*}"
  echo "    - delete the nginx vhost"
  echo "    - delete user 'monitor' and network $NET_NAME"
  echo
  echo "  Backups live in $HOME/backups/monitoring-setup-*"
  confirm

  if [ -f "$PROJECT/docker-compose.yaml" ]; then
    ( cd "$PROJECT" && docker compose down ) || true
  fi

  $SUDO rm -f "/etc/ssh/sshd_config.d/$SSHD_DROPIN"
  $SUDO sshd -t && $SUDO systemctl reload ssh && c_ok "sshd restored"

  # Remove UFW rules by matching their comment text, not by number (numbers shift).
  while $SUDO ufw status numbered 2>/dev/null | grep -q "monitoring tunnel\|monitoring node_exporter"; do
    local n
    n="$($SUDO ufw status numbered | grep 'monitoring tunnel\|monitoring node_exporter' | head -1 | awk -F']' '{print $1}' | tr -d '[')"
    echo y | $SUDO ufw delete "$n" || break
  done
  c_ok "ufw rules removed"

  rm -f "$HOME/docker/nginx/config/nginx/conf.d/${GRAFANA_HOST}.conf"
  rm -f "/etc/nginx/sites-enabled/${GRAFANA_HOST}.conf" "/etc/nginx/sites-available/${GRAFANA_HOST}.conf"
  if docker ps --format '{{.Names}}' | grep -qx nginx_proxy; then
    docker exec nginx_proxy nginx -t 2>&1 | grep -v ssl_stapling || true
    docker exec nginx_proxy nginx -s reload
    c_ok "nginx vhost removed"
  elif have nginx; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx && c_ok "nginx vhost removed"
  fi

  $SUDO userdel -r monitor 2>/dev/null && c_ok "user monitor removed" || c_note "user monitor: nothing to remove"
  docker network rm "$NET_NAME" 2>/dev/null && c_ok "network $NET_NAME removed" || c_note "network $NET_NAME: still in use or absent"

  echo
  c_ok "rollback complete."
  echo "  To also delete stored metrics:  cd $PROJECT && docker compose down -v"
}

need_root() {
  [ "$(id -u)" -eq 0 ] && SUDO="" || { have sudo || die "sudo not found"; SUDO="sudo"; }
}

# Run a mutating command, or describe it under --dry-run.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '       [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Same, for shell snippets (so we never eval in dry-run).
sh_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '       [dry-run] %s\n' "$1"
  else
    bash -c "$1"
  fi
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  local reply
  read -r -p "  proceed? [y/N] " reply
  case "$reply" in [yY]*) return 0 ;; *) die "aborted by operator" ;; esac
}

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    --rollback)       ROLLBACK=1 ;;
    --subnet)         SUBNET="$2"; GATEWAY="${2%0/24}1"; shift ;;
    --domain)         DOMAIN="$2"; shift ;;
    --grafana-host)   GRAFANA_HOST="$2"; shift ;;
    --project)        PROJECT="$2"; shift ;;
    --add-client-key) CLIENT_KEY="$2"; shift ;;
    --web)            WEB_MODE="$2"; shift ;;
    --no-admin)       NO_ADMIN=1 ;;
    --admin-url)      ADMIN_URL="$2"; shift ;;
    --help|-h)        usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

need_root
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

[ "$ROLLBACK" -eq 1 ] && { rollback; exit 0; }
[ -n "$CLIENT_KEY" ] && { add_client_key; exit 0; }

# =========================================================== 0. preflight ====
c_step "Preflight"
have docker || die "docker not installed"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (are you in the docker group / running as root?)"

# Web publishing is optional. With --web none we skip nginx entirely and Grafana
# is reachable only over an SSH tunnel, so we must not require an nginx container.
case "$WEB_MODE" in
  nginx|none) ;;
  *) die "--web must be 'nginx' or 'none' (got '$WEB_MODE')" ;;
esac

NGINX_CONF_DIR="$HOME/docker/nginx/config/nginx/conf.d"
NGINX_IS_CONTAINER=0
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nginx_proxy; then
  NGINX_IS_CONTAINER=1
fi

if [ "$WEB_MODE" = "nginx" ]; then
  if [ "$NGINX_IS_CONTAINER" -eq 1 ]; then
    NGINX_CONF_DIR="$HOME/docker/nginx/config/nginx/conf.d"
  elif have nginx; then
    NGINX_IS_CONTAINER=0
    NGINX_CONF_DIR="/etc/nginx/sites-available"
    c_ok "using native nginx (no nginx_proxy container found)"
  else
    die "--web nginx was requested but no nginx container and no native nginx found.
  Use --web none to skip the web server entirely and reach Grafana over SSH."
  fi
  [ -d "$NGINX_CONF_DIR" ] || die "nginx config dir not found: $NGINX_CONF_DIR"
else
  c_ok "--web none: no web server configured."
  c_note "Grafana will listen on 127.0.0.1:3000 inside its container only."
  c_note "Reach it with:  ssh -L 3000:172.18.0.1:3000 <this-server>"
fi

# proxy_net only matters when nginx publishes Grafana.
if [ "$WEB_MODE" = "nginx" ]; then
  if ! docker network inspect "$PROXY_NET" >/dev/null 2>&1; then
    c_warn "$PROXY_NET is missing — creating it"
    run docker network create "$PROXY_NET"
  fi
fi

# The monitoring subnet must not collide with anything else already routed.
# It is fine if it IS our own existing monitoring_net bridge — that means this is
# a re-run and we must not treat our own network as a conflict.
OWN_SUBNET=""
if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  OWN_SUBNET="$(docker network inspect "$NET_NAME" \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
  c_ok "$NET_NAME already exists (subnet ${OWN_SUBNET:-unknown}) — continuing as a re-run"
fi
if [ -z "$OWN_SUBNET" ] && ip -br route | grep -q "${SUBNET%/*}"; then
  die "subnet ${SUBNET%/*} already in use by something else: $(ip -br route | grep "${SUBNET%/*}")"
fi
[ -n "$OWN_SUBNET" ] || c_ok "subnet $SUBNET is free"
c_ok "docker + nginx_proxy present"

# Warn loudly: an sshd mistake here is the one way to lock yourself out.
c_warn "keep your current SSH session open until this finishes"
c_warn "we validate sshd config with 'sshd -t' before every reload"

# =========================================================== 1. backup =======
c_step "Backup of everything we touch"
BD="$HOME/backups/monitoring-setup-$(date +%F-%H%M%S)"
run mkdir -p "$BD"
sh_run "$SUDO cp -a /etc/ssh/sshd_config.d '$BD/sshd_config.d'"
sh_run "$SUDO ufw status numbered > '$BD/ufw-before.txt'"
sh_run "$SUDO ufw status numbered | grep -q . && $SUDO cp /etc/ufw/user.rules '$BD/ufw-user.rules' || true"
sh_run "cp -a '$HOME/docker/nginx/config/nginx/conf.d' '$BD/nginx-conf.d' 2>/dev/null || true"
c_ok "backup dir: $BD"

# =========================================================== 2. network ======
c_step "Docker network $NET_NAME"
if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  c_ok "already exists"
else
  run docker network create --subnet "$SUBNET" --gateway "$GATEWAY" "$NET_NAME"
  c_ok "created $SUBNET gw $GATEWAY"
fi

# =========================================================== 3. tunnel user ===
c_step "Restricted tunnel user 'monitor'"
if getent passwd monitor >/dev/null; then
  c_ok "already exists"
else
  sh_run "$SUDO useradd -m -s /usr/sbin/nologin -c 'Monitoring reverse tunnels' monitor"
fi
sh_run "$SUDO usermod -p '*' monitor"
sh_run "$SUDO install -d -m 700 -o monitor -g monitor /home/monitor/.ssh"
sh_run "$SUDO touch /home/monitor/.ssh/authorized_keys"
sh_run "$SUDO chown monitor:monitor /home/monitor/.ssh/authorized_keys"
sh_run "$SUDO chmod 600 /home/monitor/.ssh/authorized_keys"
c_ok "monitor: nologin shell, locked password, key-only"

# =========================================================== 4. sshd =========
c_step "sshd drop-in $SSHD_DROPIN"
# CRITICAL (learned the hard way): UFW port RANGES create no kernel rule when the
# multiport extension is missing, while still appearing in `ufw status`. The
# PermitListen list below uses individual ports for the same reason.
PERMIT_LINE=""
for p in "${TUNNEL_PORTS[@]}"; do
  PERMIT_LINE+=" $GATEWAY:$p"
done

cat > "$STAGE/$SSHD_DROPIN" <<EOF
Match User monitor
    AllowTcpForwarding remote
    GatewayPorts clientspecified
    PermitListen$PERMIT_LINE
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
    ClientAliveInterval 15
    ClientAliveCountMax 3
    ForceCommand /usr/sbin/nologin
EOF

echo "  --- proposed $SSHD_DROPIN ---"
sed 's/^/       /' "$STAGE/$SSHD_DROPIN"
confirm

sh_run "$SUDO install -m 644 '$STAGE/$SSHD_DROPIN' /etc/ssh/sshd_config.d/$SSHD_DROPIN"

# Validate BEFORE reloading. Never reload a config that fails -t.
if [ "$DRY_RUN" -eq 1 ]; then
  c_note "[dry-run] would run: sshd -t && systemctl reload ssh"
else
  $SUDO sshd -t || die "sshd config INVALID — not reloading. Fix $STAGE/$SSHD_DROPIN"
  c_ok "sshd -t passed"
  $SUDO systemctl reload ssh
  c_ok "sshd reloaded"
  c_ok "effective: $($SUDO sshd -T -C user=monitor,host=x,addr=1.2.3.4 \
        | grep -Ei '^(allowtcpforwarding|gatewayports|permitlisten|forcecommand|clientaliveinterval) ' | tr '\n' ' ')"
fi

# =========================================================== 5. ufw ==========
c_step "Firewall (individual ports only — never a range)"
for p in "${TUNNEL_PORTS[@]}"; do
  run $SUDO ufw allow from "${SUBNET%/*}" to any port "$p" proto tcp comment "monitoring tunnel $p"
done
run $SUDO ufw allow from "${SUBNET%/*}" to any port 9100 proto tcp comment 'monitoring node_exporter'

if [ "$DRY_RUN" -eq 0 ]; then
  # Verify UFW's claims against the kernel. This is the check the tutorial omits.
  missing=0
  for p in "${TUNNEL_PORTS[@]}" 9100; do
    if ! $SUDO iptables-save | grep -q "${SUBNET%/*}.*dport $p"; then
      c_err "UFW lists the rule but the kernel has none for port $p"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] && c_ok "all rules verified present in the kernel" \
                      || die "firewall incomplete — do not continue"
fi

# =========================================================== 6. project ======
c_step "Project files in $PROJECT"
mkdir -p "$STAGE/proj"/{ssh,http-over-ssh,prometheus/rules,grafana/provisioning/datasources}

# ---- proxy key (the client's promssh key is derived from its public half)
if [ -f "$PROJECT/ssh/id_ed25519" ]; then
  c_ok "proxy key already exists (reused)"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    c_note "[dry-run] would generate $PROJECT/ssh/id_ed25519"
  else
    mkdir -p "$PROJECT/ssh"
    ssh-keygen -t ed25519 -N '' -C 'http-over-ssh@monitoring' -f "$PROJECT/ssh/id_ed25519" -q
    chmod 700 "$PROJECT/ssh"; chmod 600 "$PROJECT/ssh/id_ed25519"
    c_ok "proxy key generated"
  fi
fi

# ---- Dockerfile: pinned version, NOT latest (proxy paths are load-bearing)
cat > "$STAGE/proj/http-over-ssh/Dockerfile" <<EOF
FROM golang:1-alpine AS build
# Pinned to v0.3.7. Do not use @latest: the key path and known_hosts handling
# are relied on by docker-compose.yaml.
ARG VERSION=$PROXY_VERSION
RUN CGO_ENABLED=0 GOBIN=/out go install github.com/digineo/http-over-ssh@\${VERSION}

FROM alpine:3
RUN apk add --no-cache ca-certificates
COPY --from=build /out/http-over-ssh /usr/local/bin/http-over-ssh
ENTRYPOINT ["http-over-ssh"]
EOF

# ---- compose
# Grafana only joins proxy_net when nginx publishes it; otherwise it stays on
# monitoring_net alone and is reached over an SSH tunnel.
if [ "$WEB_MODE" = "nginx" ]; then
  GRAFANA_NETS="monitoring_net, proxy_net"
  GRAFANA_ROOT_URL="https://$GRAFANA_HOST.$DOMAIN"
  COOKIE_SECURE="true"
else
  GRAFANA_NETS="monitoring_net"
  GRAFANA_ROOT_URL="http://localhost:3000"
  # Over plain HTTP an SSH tunnel, a "secure" cookie is never sent back and the
  # login loop never completes. This must be false in this mode.
  COOKIE_SECURE="false"
fi
cat > "$STAGE/proj/docker-compose.yaml" <<EOF
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=\${PROM_RETENTION_TIME}
      - --storage.tsdb.retention.size=\${PROM_RETENTION_SIZE}
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prometheus_data:/prometheus
    # Bound to loopback ONLY, so the admin panel (a host process) can query
    # /api/v1/query for device health without joining monitoring_net. Loopback
    # binding means nothing is reachable from the internet or the LAN. Remove
    # this block if you run the panel as a container on the same network.
    ports:
      - "127.0.0.1:\${PROM_HOST_PORT:-9090}:9090"
    networks: [monitoring_net]
    security_opt: [no-new-privileges:true]

  http-over-ssh:
    build: ./http-over-ssh
    image: http-over-ssh:local
    container_name: http-over-ssh
    restart: unless-stopped
    user: "\${PUID}:\${PGID}"
    # There is NO key-file flag. The binary reads keys AND known_hosts from
    # \$HOS_KEY_DIR, and log.Fatal()s if known_hosts is missing.
    command: ["-listen", "0.0.0.0:8080"]
    environment:
      HOS_KEY_DIR: /ssh
    volumes:
      - ./ssh:/ssh:ro
    networks: [monitoring_net]
    security_opt: [no-new-privileges:true]

  grafana:
    image: grafana/grafana-oss:latest
    container_name: grafana
    restart: unless-stopped
    environment:
      GF_SERVER_ROOT_URL: $GRAFANA_ROOT_URL
      GF_SECURITY_ADMIN_USER: \${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: \${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_SECURITY_COOKIE_SECURE: "${COOKIE_SECURE}"
      GF_ANALYTICS_REPORTING_ENABLED: "false"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    networks: [$GRAFANA_NETS]
    security_opt: [no-new-privileges:true]

volumes:
  prometheus_data:
  grafana_data:
networks:
  monitoring_net: { external: true }
  proxy_net: { external: true }
EOF
# With --web none nothing attaches Grafana to proxy_net, and an unused external
# network declaration would make compose fail, so strip it.
if [ "$WEB_MODE" = "none" ]; then
  sed -i '/^  proxy_net: { external: true }$/d' "$STAGE/proj/docker-compose.yaml"
fi

# ---- prometheus.yml. Targets come from the scrape list below.
DEVICES=()
[ -f "$PROJECT/devices.list" ] && mapfile -t DEVICES < "$PROJECT/devices.list"

{
cat <<'EOF'
global:
  scrape_interval: 30s
  scrape_timeout: 25s
  evaluation_interval: 30s

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: http-over-ssh
    static_configs:
      - targets: ['http-over-ssh:8080']

  # Remote devices reached through the SSH proxy.
  # Target = the SSH endpoint of the device (host:port), not the exporter.
  - job_name: node-ssh
    proxy_url: http://http-over-ssh:8080/
    metrics_path: /localhost:9100/metrics
    basic_auth:
      username: promssh
      password: unused
    relabel_configs:
      - source_labels: [device]
        target_label: instance
    static_configs:
EOF
if [ ${#DEVICES[@]} -eq 0 ]; then
  printf "      - targets: ['%s:%s']\n        labels:\n          device: g14\n" "$GATEWAY" "${TUNNEL_PORTS[0]}" \
    | sed "s/g14\$/REPLACE_ME/"
else
  for d in "${DEVICES[@]}"; do
    [ -z "$d" ] && continue
    name="${d%%:*}"; port="${d##*:}"
    printf "      - targets: ['%s:%s']\n        labels:\n          device: %s\n" "$GATEWAY" "$port" "$name"
  done
fi
cat <<'EOF'

  # The VPS itself — node_exporter on the monitoring_net bridge gateway.
  - job_name: node-local
    static_configs:
      - targets: ['GATEWAY:9100']
        labels:
          device: THISHOST
    relabel_configs:
      - source_labels: [device]
        target_label: instance
EOF
} | sed -e "s|GATEWAY:9100|${GATEWAY}:9100|" -e "s|device: THISHOST|device: $(hostname -s 2>/dev/null || echo vps)|" \
  > "$STAGE/proj/prometheus/prometheus.yml"

# ---- alert rules. vfat excluded: /boot/efi always reads 100% full.
cat > "$STAGE/proj/prometheus/rules/node.yml" <<'EOF'
groups:
  - name: node
    rules:
      - alert: DeviceDown
        expr: up{job="node-ssh"} == 0
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }} has not been scraped for 10 minutes"

      - alert: ProxyDown
        expr: up{job="http-over-ssh"} == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "http-over-ssh proxy is down"

      - alert: HighMemory
        expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.90
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }} memory above 90%"

      # vfat excluded: /boot/efi is a small EFI partition that always reports
      # ~100% full and would otherwise fire on every scrape.
      - alert: LowDisk
        expr: node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs|vfat"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs|vfat"} < 0.10
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }} {{ $labels.mountpoint }} has under 10% free"

      - alert: HighCPU
        expr: 1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.90
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }} CPU above 90% for 15 minutes"
EOF

# ---- grafana datasource
cat > "$STAGE/proj/grafana/provisioning/datasources/prometheus.yml" <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 30s
EOF

# ---- nginx vhost (lazy-resolver pattern, matches existing vhost style)
# Skipped entirely with --web none: nothing is published to the internet.
if [ "$WEB_MODE" = "none"; then
  c_note "no nginx vhost generated (--web none)"
else
cat > "$STAGE/proj/grafana.conf" <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name $GRAFANA_HOST.$DOMAIN;

    ssl_certificate     /etc/nginx/certs/wildcard.crt;
    ssl_certificate_key /etc/nginx/certs/wildcard.key;

    add_header X-Frame-Options        "SAMEORIGIN"    always;
    add_header X-Content-Type-Options "nosniff"       always;
    add_header Referrer-Policy        "strict-origin-when-cross-origin" always;

    limit_req  zone=general burst=50 nodelay;
    limit_conn conn_per_ip 20;

    resolver 127.0.0.11 valid=10s ipv6=off;
    set \$upstream http://grafana:3000;

    location = /login {
        if (\$bad_bot) { return 403; }
        limit_req zone=auth burst=10 nodelay;

        proxy_pass \$upstream;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        if (\$bad_bot) { return 403; }

        proxy_pass \$upstream;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}

server {
    listen 80;
    server_name $GRAFANA_HOST.$DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF
fi  # end --web none vhost guard

if [ "$WEB_MODE" = "nginx" ]; then
  c_ok "staged: compose, prometheus.yml, rules, datasource, Dockerfile, nginx vhost"
else
  c_ok "staged: compose, prometheus.yml, rules, datasource, Dockerfile (no vhost)"
fi
confirm

# ---- publish
sh_run "mkdir -p '$PROJECT'"
sh_run "cp -a '$STAGE/proj/.' '$PROJECT/'"
sh_run "chmod 644 '$PROJECT/prometheus/prometheus.yml' '$PROJECT/prometheus/rules/node.yml' '$PROJECT/grafana/provisioning/datasources/prometheus.yml'"

	# ---- publish the installer somewhere a service account can read
	# The admin panel runs as its own unprivileged user and serves install.sh.
	# A git clone under /home/<user> is mode 750, so it cannot read it from
	# there; install a copy under /usr/local/share instead of loosening the
	# home directory's permissions.
	INSTALL_SHARE="/usr/local/share/monitoring"
	sh_run "install -d -m 755 '$INSTALL_SHARE'"
	if [ -f "$SCRIPT_DIR/install.sh" ]; then
	  sh_run "install -m 644 '$SCRIPT_DIR/install.sh' '$INSTALL_SHARE/install.sh'"
	  c_ok "installer published at $INSTALL_SHARE/install.sh"
	else
	  c_warn "install.sh not found next to this script; the panel will not serve it"
	fi

# ---- .env (generate the password, never hardcode one)
if [ "$DRY_RUN" -eq 1 ]; then
  c_note "[dry-run] would generate $PROJECT/.env with a random admin password"
else
  if [ -f "$PROJECT/.env" ]; then
    c_ok ".env exists (kept — not overwriting your password)"
  else
    umask 077
    printf 'PUID=%s\nPGID=%s\nGRAFANA_ADMIN_USER=admin\nGRAFANA_ADMIN_PASSWORD=%s\nPROM_RETENTION_TIME=%s\nPROM_RETENTION_SIZE=%s\n' \
      "$(id -u)" "$(id -g)" "$(openssl rand -base64 24 | tr -d '\n')" \
      "$RETENTION_TIME" "$RETENTION_SIZE" > "$PROJECT/.env"
    c_ok ".env written (mode 600, random password)"
  fi
fi

# known_hosts must EXIST or the proxy log.Fatal()s. Empty file = comment only.
if [ ! -f "$PROJECT/ssh/known_hosts" ]; then
  cat > "$PROJECT/ssh/known_hosts" <<EOF
# http-over-ssh host key pinning. One line per device, ALL key types.
# The proxy refuses to start without this file, and rejects any unlisted key
# type for a host it already knows — so pin every type the device offers.
#
#   ssh-keyscan -p $GATEWAY ${TUNNEL_PORTS[0]} 2>/dev/null | grep -v '^#' >> ssh/known_hosts
#
# entries look like: [$GATEWAY]:2201 ssh-ed25519 AAAA...
EOF
  c_ok "known_hosts placeholder created"
fi

# =========================================================== 7. node_exporter =
c_step "node_exporter for the VPS itself"
if ! have prometheus-node-exporter && ! [ -x /usr/bin/prometheus-node-exporter ]; then
  if have apt-get; then
    sh_run "$SUDO apt-get install -y prometheus-node-exporter"
  elif have dnf; then
    sh_run "$SUDO dnf install -y prometheus-node-exporter"
  elif have pacman; then
    sh_run "$SUDO pacman -S --needed prometheus-node-exporter"
  else
    c_warn "no known package manager — install prometheus-node-exporter manually"
  fi
fi

cat > "$STAGE/node-exporter-default" <<EOF
# Bound to the monitoring bridge gateway only — never a public interface.
# This address exists only once Docker creates the network, hence the
# After=docker.service + Restart=always drop-in.
ARGS="--web.listen-address=$GATEWAY:9100"
EOF

cat > "$STAGE/node-exporter-override.conf" <<'EOF'
[Unit]
After=docker.service

[Service]
Restart=always
RestartSec=10
EOF

sh_run "$SUDO install -m 644 '$STAGE/node-exporter-default' /etc/default/prometheus-node-exporter 2>/dev/null || true"
sh_run "$SUDO mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d"
sh_run "$SUDO install -m 644 '$STAGE/node-exporter-override.conf' /etc/systemd/system/prometheus-node-exporter.service.d/override.conf"
sh_run "$SUDO systemctl daemon-reload"
sh_run "$SUDO systemctl enable --now prometheus-node-exporter"
sh_run "$SUDO systemctl restart prometheus-node-exporter"

# =========================================================== 8. validate ======
c_step "Validate configs BEFORE starting anything"
sh_run "cd '$PROJECT' && docker compose config -q"
sh_run "cd '$PROJECT' && docker run --rm --entrypoint promtool -v '$PROJECT/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro' -v '$PROJECT/prometheus/rules:/etc/prometheus/rules:ro' prom/prometheus:latest check config /etc/prometheus/prometheus.yml"
confirm

# =========================================================== 9. start =========
c_step "Build and start the stack"
sh_run "cd '$PROJECT' && docker compose build"
sh_run "cd '$PROJECT' && docker compose up -d"

if [ "$WEB_MODE" = "none" ]; then
  c_step "Web publishing: skipped (--web none)"
  c_note "Grafana is bound to its container only. Nothing new is exposed."
  c_note "Reach it from your machine with:"
  c_note "  ssh -L 3000:$GATEWAY:3000 <this-server>"
  if [ "$DRY_RUN" -eq 0 ]; then
    # Publish a loopback-only port so `ssh -L` has something to land on.
    sh_run "docker compose -f '$PROJECT/docker-compose.yaml' up -d grafana 2>/dev/null || true"
  fi
else
  c_step "Publish through nginx ($([ "$NGINX_IS_CONTAINER" -eq 1 ] && echo container || echo native))"
  sh_run "cp '$STAGE/proj/grafana.conf' '$NGINX_CONF_DIR/${GRAFANA_HOST}.conf'"
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$NGINX_IS_CONTAINER" -eq 1 ]; then
      # test, then reload only on success
      docker exec nginx_proxy nginx -t 2>&1 | grep -v ssl_stapling || die "nginx config invalid — not reloading"
      docker exec nginx_proxy nginx -s reload
    else
      nginx -t >/dev/null 2>&1 || die "nginx config invalid — not reloading"
      systemctl reload nginx || systemctl restart nginx
    fi
    c_ok "nginx reloaded"
  fi
fi

c_step "Admin panel (optional, --admin <url-path> or --no-admin)"
# The panel mints one-line install commands and shows device health. It is a
# separate binary so people who only want Grafana never need Go.
if [ "$NO_ADMIN" -eq 1 ]; then
  c_note "skipped (--no-admin)"
else
  ADMIN_URL="${ADMIN_URL:-}"
  if [ -n "$ADMIN_URL" ] && have curl; then
    if curl -fsS -m 10 -o /dev/null "$ADMIN_URL" 2>/dev/null; then
      c_ok "existing panel reachable at $ADMIN_URL — leaving it alone"
    else
      c_warn "no panel at $ADMIN_URL; run the docker server script or install the binary:"
      c_note "  make -C $0 install && systemctl enable --now monitoring-admin"
    fi
  else
    c_note "no panel detected. The docker server script installs one automatically;"
    c_note "for the native path:  make install && systemctl enable --now monitoring-admin"
  fi
  c_note "the installer is always available from the panel at <domain>/install.sh"
fi

# =========================================================== 10. bundle =======
c_step "Client bundle"
VPS_IP="$(ip -4 -br addr show scope global 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1)"
[ -z "$VPS_IP" ] && VPS_IP="<set-your-vps-ip>"
HOST_FPR="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')"
PROXY_PUB=""
[ -f "$PROJECT/ssh/id_ed25519.pub" ] && PROXY_PUB="$(cat "$PROJECT/ssh/id_ed25519.pub")"
GF_PW=""
[ -f "$PROJECT/.env" ] && GF_PW="$(grep '^GRAFANA_ADMIN_PASSWORD=' "$PROJECT/.env" | cut -d= -f2-)"

if [ "$DRY_RUN" -eq 0 ]; then
  umask 077
  cat > "$PROJECT/client-bundle.env" <<EOF
# Copy this file to the client machine. Consumed by monitoring-client-setup.sh
#   scp $PROJECT/client-bundle.env <client>:
#   ./monitoring-client-setup.sh --bundle client-bundle.env
VPS_HOST=$VPS_IP
VPS_HOST_KEY_FINGERPRINT=$HOST_FPR
TUNNEL_PORT=${TUNNEL_PORTS[0]}
PROXY_PUBKEY=$PROXY_PUB
GRAFANA_URL=https://$GRAFANA_HOST.$DOMAIN
GRAFANA_USER=admin
GRAFANA_PASSWORD=$GF_PW
EOF
  c_ok "written: $PROJECT/client-bundle.env"
else
  c_note "[dry-run] would write $PROJECT/client-bundle.env"
fi

cat <<EOF

$(printf '\033[1;32m')=========================================================
 Server side complete.
=========================================================$(printf '\033[0m')

 Next: run the client script on each machine.

   1. copy the bundle + client script across:
        scp $PROJECT/client-bundle.env ./monitoring-client-setup.sh <client>:
   2. on the client:
        chmod +x monitoring-client-setup.sh
        ./monitoring-client-setup.sh --bundle client-bundle.env --dry-run
        ./monitoring-client-setup.sh --bundle client-bundle.env
   3. the client prints one 'authorized_keys' line — paste it into
        /home/monitor/.ssh/authorized_keys on THIS machine
      or pass it straight back:
        sudo ./monitoring-server-setup.sh --add-client-key "<line>"

 Grafana: https://$GRAFANA_HOST.$DOMAIN   (admin / see client-bundle.env)

EOF