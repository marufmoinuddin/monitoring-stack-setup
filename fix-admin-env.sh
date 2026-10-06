#!/usr/bin/env bash
# Repair the monitoring-admin environment file.
#
# The bug: MON_PROXY_PUBKEY holds an SSH public key, which contains a SPACE
# ("ssh-ed25519 AAAA..."). systemd's EnvironmentFile= splits assignments on
# whitespace, so the key was truncated to "ssh-ed25519" and the comment became a
# stray variable. Fixing the key is not enough on its own: MON_DOMAIN is also a
# bare hostname here, so the panel derived its installer URL from the wrong
# base.
#
# This script writes a clean env file where:
#   - the pubkey is read from disk into MON_PROXY_PUBKEY (no splitting), and
#   - MON_INSTALL_BASE names the PANEL's own host, which is where /install.sh
#     is actually served. Pointing it at Grafana returns Grafana's login page.
set -euo pipefail

ENV_FILE=/etc/monitoring/admin.env
KEY_FILE=${1:-/usr/local/share/monitoring/proxy/id_ed25519.pub}
PROXY_GW=$(docker network inspect proxy_net --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
PANEL_HOST=monitor-admin.monitor.example.com
GF_HOST=grafana.monitor.example.com

[ -f "$KEY_FILE" ] || { echo "pubkey not found: $KEY_FILE" >&2; exit 1; }
# Read the whole line, minus trailing whitespace/newline. No word splitting.
PROXY_PUBKEY=$(tr -d '\n' < "$KEY_FILE")

umask 077
cat > "$ENV_FILE" <<EOF
# monitoring-admin configuration. Mode 600: contains the proxy public key.
#
# MON_PROXY_PUBKEY is written unquoted because systemd's EnvironmentFile= splits
# on whitespace and would truncate a quoted value too. The key must therefore
# live on ONE line with no shell quoting around it.
MON_LISTEN=${PROXY_GW}:8099
MON_DOMAIN=${GF_HOST}
MON_INSTALL_BASE=https://${PANEL_HOST}
MON_TUNNEL_HOST=172.30.0.1
MON_TUNNEL_USER=monitor
MON_PROMETHEUS_URL=http://127.0.0.1:9090
MON_PROXY_PUBKEY=${PROXY_PUBKEY}
MON_REPO_DIR=/usr/local/share/monitoring
EOF

chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE"
grep -v '^#' "$ENV_FILE" | sed -E 's/^(MON_PROXY_PUBKEY)=.*/\1=<pubkey ok>/' | sed 's/^/  /'