#!/usr/bin/env bash
# =============================================================================
# monitoring-client-setup.sh — client half of the Grafana + Prometheus +
# http-over-ssh monitoring stack. Sets up a monitored Linux machine (laptop,
# home server, anything behind NAT) with NO inbound ports and NO VPN.
#
# Run this ON THE CLIENT, with the bundle produced by monitoring-server-setup.sh:
#
#   ./monitoring-client-setup.sh --bundle ~/client-bundle.env --dry-run
#   ./monitoring-client-setup.sh --bundle ~/client-bundle.env
#
# It will:
#   1. install autossh + node_exporter, bound exporter to 127.0.0.1 only
#   2. create the tunnel keypair and print the authorized_keys line for the server
#   3. pin the server's SSH host key (fingerprint-verified from the bundle)
#   4. create the 'promssh' account so only the metrics port is reachable
#   5. install the autossh systemd unit so the tunnel survives sleep/reboot
#
# Then paste the printed public key into the server's authorized_keys, or run
# on the server:  ./monitoring-server-setup.sh --add-client-key "<line>"
#
# Idempotent: safe to re-run. Requires root (or sudo).
# =============================================================================
set -euo pipefail

BUNDLE=""
DRY_RUN=0
ASSUME_YES=0
SKIP_UNIT=0
DEVICE_NAME="${DEVICE_NAME:-$(hostname -s 2>/dev/null || echo client)}"
BUNDLE_PATH=""

SUDO=""
c_ok()   { printf '\033[0;32m  ok\033[0m   %s\n' "$*"; }
c_warn() { printf '\033[0;33m  warn\033[0m %s\n' "$*"; }
c_err()  { printf '\033[0;31m  fail\033[0m %s\n' "$*" >&2; }
c_step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
c_note() { printf '       %s\n' "$*"; }
die()    { c_err "$*"; exit 1; }
have()   { command -v "$1" >/dev/null 2>&1; }

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
  local r
  read -r -p "  proceed? [y/N] " r
  case "$r" in [yY]*) return 0 ;; *) die "aborted by operator" ;; esac
}

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle)   BUNDLE="$2"; shift ;;
    --name)     DEVICE_NAME="$2"; shift ;;
    --dry-run)  DRY_RUN=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --no-unit)  SKIP_UNIT=1 ;;
    --help|-h)  usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] && SUDO="" || { have sudo || die "sudo not found"; SUDO="sudo"; }

# ============================================================ bundle ==========
c_step "Reading server bundle"
if [ -z "$BUNDLE" ]; then
  # Look for it in the usual places so the operator does not have to type a path.
  for cand in "$HOME/client-bundle.env" "$HOME/docker/monitoring/client-bundle.env" \
              "./client-bundle.env" "$HOME/.client-bundle.env"; do
    if [ -f "$cand" ]; then BUNDLE="$cand"; break; fi
  done
  [ -n "$BUNDLE" ] || die "no --bundle given and none found in the usual places.
  Get it from the server:  scp <server>:~/docker/monitoring/client-bundle.env ~/"
fi
[ -f "$BUNDLE" ] || die "bundle not found: $BUNDLE"

# Bundle is a flat KEY=VALUE file.
#
# We PARSE it rather than sourcing it, for two reasons:
#   1. Values legitimately contain spaces (PROXY_PUBKEY is a full
#      "ssh-ed25519 AAAA... comment" line), which `.` would treat as a command.
#   2. Sourcing a file that arrived over the network would execute whatever it
#      contains. Parsing cannot run code.
bundle_get() {
  local key="$1"
  sed -n "s/^${key}=\(.*\)$/\1/p" "$BUNDLE" | head -1
}

# Refuse obvious injection attempts outright, as defence in depth.
if grep -qE '\$\(|`|&&|;' "$BUNDLE"; then
  die "bundle contains shell metacharacters — refusing to parse. Expected plain KEY=VALUE lines."
fi

VPS_HOST="$(bundle_get VPS_HOST)"
PROXY_PUBKEY="$(bundle_get PROXY_PUBKEY)"
TUNNEL_PORT="$(bundle_get TUNNEL_PORT)"
VPS_HOST_KEY_FINGERPRINT="$(bundle_get VPS_HOST_KEY_FINGERPRINT)"
GRAFANA_URL="$(bundle_get GRAFANA_URL)"
GRAFANA_USER="$(bundle_get GRAFANA_USER)"
GRAFANA_PASSWORD="$(bundle_get GRAFANA_PASSWORD)"

for v in VPS_HOST PROXY_PUBKEY TUNNEL_PORT; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "bundle is missing a value for $v"
done
case "$TUNNEL_PORT" in
  ''|*[!0-9]*) die "TUNNEL_PORT must be numeric, got '$TUNNEL_PORT'" ;;
esac
case "$PROXY_PUBKEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
  *) die "PROXY_PUBKEY does not look like an SSH public key" ;;
esac
c_ok "bundle: $BUNDLE"
c_ok "server  : $VPS_HOST (tunnel port $TUNNEL_PORT)"
[ -n "${VPS_HOST_KEY_FINGERPRINT:-}" ] && c_ok "expected host key: $VPS_HOST_KEY_FINGERPRINT"
[ -n "${GRAFANA_URL:-}" ] && c_note "grafana: $GRAFANA_URL"
case "${GRAFANA_URL:-}" in
  https://*) c_note "the server publishes Grafana over HTTPS" ;;
  *)        c_note "the server keeps Grafana on loopback — open a tunnel:"
            c_note "  ssh -L 3000:127.0.0.1:3000 $VPS_HOST"
            c_note "then browse http://127.0.0.1:3000" ;;
esac

# ============================================================ packages =======
c_step "Packages"
PKG_MGR=""
if   have pacman;  then PKG_MGR="pacman"
elif have apt-get; then PKG_MGR="apt"
elif have dnf;     then PKG_MGR="dnf"
elif have zypper;  then PKG_MGR="zypper"
else die "no supported package manager found (need pacman/apt/dnf/zypper)"
fi
c_ok "package manager: $PKG_MGR"

case "$PKG_MGR" in
  pacman) sh_run "$SUDO pacman -S --needed --noconfirm autossh prometheus-node-exporter" ;;
  apt)    sh_run "$SUDO apt-get update -qq && $SUDO apt-get install -y autossh prometheus-node-exporter" ;;
  dnf)    sh_run "$SUDO dnf install -y autossh prometheus-node-exporter" ;;
  zypper) sh_run "$SUDO zypper --non-interactive install autossh prometheus-node-exporter" ;;
esac

EXPORTER_BIN=""
for p in /usr/bin/prometheus-node-exporter /usr/local/bin/prometheus-node-exporter; do
  [ -x "$p" ] && EXPORTER_BIN="$p" && break
done
[ -n "$EXPORTER_BIN" ] || c_warn "could not locate the exporter binary; assuming /usr/bin/prometheus-node-exporter"
EXPORTER_BIN="${EXPORTER_BIN:-/usr/bin/prometheus-node-exporter}"

# ============================================================ exporter =======
c_step "node_exporter on loopback only"
# Without this the exporter answers on every interface, so anyone on the same
# Wi-Fi can read your machine's stats.
UNIT_EXPORTER="prometheus-node-exporter.service"
if systemctl list-unit-files 2>/dev/null | grep -q "^${UNIT_EXPORTER}"; then
  # Same /etc permission issue as the tunnel unit: stage, then install with sudo.
  STAGED_EXP="$(mktemp)"
  cat > "$STAGED_EXP" <<EOF
[Service]
# Cleared then replaced: binds to loopback so the exporter is not reachable
# from the local network. The cleared ExecStart is required.
ExecStart=
ExecStart=$EXPORTER_BIN --web.listen-address=127.0.0.1:9100
EOF
  sh_run "$SUDO mkdir -p /etc/systemd/system/${UNIT_EXPORTER}.d"
  sh_run "$SUDO install -m 644 '$STAGED_EXP' /etc/systemd/system/${UNIT_EXPORTER}.d/override.conf"
  rm -f "$STAGED_EXP"
  sh_run "$SUDO systemctl daemon-reload"
  sh_run "$SUDO systemctl enable --now $UNIT_EXPORTER"
  sh_run "$SUDO systemctl restart $UNIT_EXPORTER"
  if [ "$DRY_RUN" -eq 0 ]; then
    sleep 2
    local_state="$(systemctl is-active "$UNIT_EXPORTER")"
    exp_state="$local_state"
    [ "$exp_state" = "active" ] || die "exporter is '$exp_state' — check: journalctl -u $UNIT_EXPORTER"
    c_ok "exporter active"
    # Confirm the bind address, which is the thing that actually matters.
    if ss -lnt 2>/dev/null | grep -q '127.0.0.1:9100'; then
      c_ok "listening on 127.0.0.1:9100 (not exposed)"
    else
      c_err "NOT listening on 127.0.0.1:9100 — check ss -lntp | grep 9100"
    fi
  fi
else
  c_warn "no ${UNIT_EXPORTER} unit found — this distro may package it differently."
  c_note "run the exporter however your distro does it, bound to 127.0.0.1:9100"
fi

# ============================================================ tunnel key =====
c_step "Tunnel keypair"
KEY="$HOME/.ssh/monitoring_tunnel"
if [ -f "$KEY" ]; then
  c_ok "existing key reused: $KEY"
  TUNNEL_PUB="$(cat "$KEY.pub")"
else
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [ "$DRY_RUN" -eq 1 ]; then
    c_note "[dry-run] would generate $KEY"
    TUNNEL_PUB="ssh-ed25519 <DRY-RUN-NOT-GENERATED>"
  else
    ssh-keygen -t ed25519 -N '' -C "${DEVICE_NAME}-to-monitoring-server" -f "$KEY" -q
    c_ok "generated $KEY"
    TUNNEL_PUB="$(cat "$KEY.pub")"
  fi
fi

# ============================================================ host key pin ===
c_step "Pinning the server's SSH host key"
# We do not trust ssh-keyscan blindly: we compare against the fingerprint the
# server published in the bundle. A mismatch means we are not talking to the
# machine we think we are.
KNOWN="$HOME/.ssh/known_hosts"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$KNOWN"; chmod 600 "$KNOWN"

if [ "$DRY_RUN" -eq 1 ]; then
  c_note "[dry-run] would scan and verify $VPS_HOST against $VPS_HOST_KEY_FINGERPRINT"
else
  SCAN="$(ssh-keyscan -4 -t ed25519 "$VPS_HOST" 2>/dev/null | grep -v '^#' || true)"
  [ -n "$SCAN" ] || die "ssh-keyscan got nothing back from $VPS_HOST"

  GOT="$(printf '%s\n' "$SCAN" | ssh-keygen -lf - | awk '{print $2}')"
  if [ -n "${VPS_HOST_KEY_FINGERPRINT:-}" ] && [ "$GOT" != "$VPS_HOST_KEY_FINGERPRINT" ]; then
    c_err "HOST KEY MISMATCH — stop."
    c_note "  server said : $VPS_HOST_KEY_FINGERPRINT"
    c_note "  we scanned  : $GOT"
    c_note "  This may be an impostor. Nothing was written to known_hosts."
    exit 1
  fi
  c_ok "fingerprint matches bundle: $GOT"

  # Replace any stale entry for this host rather than appending a duplicate.
  grep -v "$VPS_HOST" "$KNOWN" > "$KNOWN.new" 2>/dev/null || true
  printf '%s\n' "$SCAN" >> "$KNOWN.new"
  mv "$KNOWN.new" "$KNOWN"; chmod 600 "$KNOWN"
  c_ok "pinned in $KNOWN"
fi

# ============================================================ promssh ========
c_step "promssh account (metrics-only login for the proxy)"
# This key can ONLY forward to the exporter. It cannot open a shell, cannot
# tunnel, and cannot reach any other port.
if ! getent passwd promssh >/dev/null; then
  sh_run "$SUDO useradd -m -s /usr/sbin/nologin -c 'monitoring metrics reader' promssh"
  sh_run "$SUDO usermod -p '*' promssh"
else
  c_ok "promssh exists"
fi
sh_run "$SUDO install -d -m 700 -o promssh -g promssh /home/promssh/.ssh"

if [ "$DRY_RUN" -eq 1 ]; then
  c_note "[dry-run] would install this line into /home/promssh/.ssh/authorized_keys:"
  c_note "  restrict,port-forwarding,permitopen=\"localhost:9100\" $PROXY_PUBKEY"
else
  AK=/home/promssh/.ssh/authorized_keys
  sudo touch "$AK"
  # Exactly one line, replaced if present (idempotent).
  printf '%s\n' "restrict,port-forwarding,permitopen=\"localhost:9100\" $PROXY_PUBKEY" \
    | sudo tee "$AK" >/dev/null
  sudo chmod 600 "$AK"
  sudo chown promssh:promssh "$AK"
  c_ok "authorized_keys written (single line, 600, owned by promssh)"

  if ! sudo sshd -T 2>/dev/null | grep -qiE '^allowtcpforwarding (yes|all)'; then
    c_warn "sshd does not allow TCP forwarding — the proxy will not be able to scrape."
    c_note "  check: sudo sshd -T | grep -i allowtcpforwarding"
  else
    c_ok "sshd permits TCP forwarding"
  fi
fi

# ============================================================ tunnel unit ===
if [ "$SKIP_UNIT" -eq 1 ]; then
  c_step "Skipping autossh unit (--no-unit)"
else
c_step "autossh tunnel service"
# The unit lives in /etc, which a non-root user cannot write. Stage it in a
# temp file and install it with sudo rather than redirecting straight into /etc.
UNIT_PATH="/etc/systemd/system/monitoring-tunnel.service"
STAGED_UNIT="$(mktemp)"
cat > "$STAGED_UNIT" <<EOF
[Unit]
Description=Reverse SSH tunnel to $VPS_HOST (monitoring)
After=network-online.target
Wants=network-online.target

[Service]
User=$(id -un)
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/bin/autossh -M 0 -N -T \\
  -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=15 \\
  -o ServerAliveCountMax=3 \\
  -o StrictHostKeyChecking=yes \\
  -o IdentitiesOnly=yes \\
  -o AddressFamily=inet \\
  -i $KEY \\
  -R 172.30.0.1:${TUNNEL_PORT}:127.0.0.1:22 \\
  monitor@$VPS_HOST
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
echo "  --- unit to be installed ---"
sed 's/^/       /' "$STAGED_UNIT"
confirm
sh_run "$SUDO install -m 644 '$STAGED_UNIT' '$UNIT_PATH'"
rm -f "$STAGED_UNIT"
sh_run "$SUDO systemctl daemon-reload"
sh_run "$SUDO systemctl enable --now monitoring-tunnel.service"
[ "$DRY_RUN" -eq 1 ] || c_ok "unit installed and enabled"
[ "$DRY_RUN" -eq 1 ] || c_note "copy of the unit: $HOME/.ssh/monitoring-tunnel.service.copy"
fi

# ============================================================ handoff ========
c_step "Hand this back to the server"
echo
if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
  DRY RUN — nothing was changed. Re-run without --dry-run to apply.
EOF
  exit 0
fi

cat <<EOF
$(printf '\033[1;33m')=========================================================
 STEP 2 — run this ON THE SERVER.
=========================================================$(printf '\033[0m')

 It installs the key, waits for your tunnel, pins your host key, and
 restarts the proxy.

   ./monitoring-server-setup.sh --add-client-key "$(printf '%s' "${TUNNEL_PUB}" | sed 's/.*\///')"

(That is your tunnel public key: ${TUNNEL_PUB})

$(printf '\033[1;33m')=========================================================
EOF
echo
echo "Or paste this single line into /home/monitor/.ssh/authorized_keys on the server:"
echo
echo "  restrict,port-forwarding,permitlisten=\"172.30.0.1:${TUNNEL_PORT}\" ${TUNNEL_PUB}"
echo
echo "  then:  sudo chown monitor:monitor /home/monitor/.ssh/authorized_keys"
echo "         sudo chmod 600 /home/monitor/.ssh/authorized_keys"
echo
echo "Tunnel status here:"
systemctl is-active monitoring-tunnel.service 2>/dev/null || true
journalctl -u monitoring-tunnel.service -n 5 --no-pager 2>/dev/null | sed 's/^/  /' || true
echo
if [ -n "${GRAFANA_URL:-}" ]; then
  echo "Grafana: ${GRAFANA_URL}"
  [ -n "${GRAFANA_USER:-}" ] && echo "  user: ${GRAFANA_USER}   (password in the bundle file — rotate it after first login)"
fi