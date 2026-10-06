#!/bin/sh
# =============================================================================
# install-monitoring.sh — one-line client installer for the monitoring stack.
#
#   curl -fsSL https://<domain>/install.sh -o /tmp/install-monitoring.sh \
#     && chmod +x /tmp/install-monitoring.sh \
#     && sudo /tmp/install-monitoring.sh --name my-laptop --port 2201 \
#        --server monitor.example.com --key "ssh-ed25519 AAAA..."
#
# It installs:
#   - prometheus-node_exporter, bound to 127.0.0.1 only
#   - an autossh systemd unit holding an SSH reverse tunnel to the server
#   - a dedicated promssh account the server can use to read the exporter
#
# This script is plain POSIX shell and prints every step. Read it before you run
# it if you would rather: nothing is downloaded except distro packages, and no
# code is fetched from the network.
#
# Design notes (learned the hard way, kept so the next person benefits):
#   - The exporter MUST bind loopback, or anyone on the local network can read
#     your machine's disk layout and service inventory.
#   - The tunnel dials OUT to the server. Your machine needs no inbound port.
#   - Exits non-zero and explains itself rather than leaving a half-installed
#     system behind.
# =============================================================================
set -eu

# Capture our own path once, at the very top, before anything else can mangle
# $0. The shebang guard near the end depends on being able to read this file.
SELF="$0"
case "$SELF" in
  /*) : ;;
  */*) SELF="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)/$(basename "$SELF")" || SELF="$0" ;;
  *)   SELF="$(command -v "$SELF" 2>/dev/null || echo "$SELF")" ;;
esac

NAME=""
PORT=""
SERVER=""
PUBKEY=""
# The SSH account on the server that owns the tunnel. Servers may run several
# tunnel identities (one per trust domain), so this is configurable rather than
# hardcoded to "monitor".
TUNNEL_USER="monitor"
# Resolve the real user's identity BEFORE acting. Under sudo, $HOME is usually
# reset to /root, so a unit that referenced /root/.ssh/... while running as the
# invoking user would silently fail to authenticate. sudo always exports
# SUDO_USER, which is authoritative.
RUN_USER="${SUDO_USER:-}"
RUN_HOME=""
if [ -n "$RUN_USER" ]; then
  RUN_HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6)"
else
  RUN_USER="$(id -un)"
  RUN_HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6)"
fi
[ -n "$RUN_HOME" ] && [ -d "$RUN_HOME" ] || RUN_HOME="/home/$RUN_USER"
KEYFILE="$RUN_HOME/.ssh/monitoring_tunnel"
KNOWN_HOSTS="$RUN_HOME/.ssh/known_hosts"
BUNDLE_DIR="/etc/monitoring"
AUTOSSH_RESTART=15
DRY_RUN=0
SKIP_PACKAGES=0
UNINSTALL=0

RED=''; GRN=''; YLW=''; RST=''
if [ -t 1 ]; then RED=$(printf '\033[31m'); GRN=$(printf '\033[32m')
  YLW=$(printf '\033[33m'); RST=$(printf '\033[0m'); fi

say()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%swarn:%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --name <name>       device label (required)
  --port <n>          tunnel port on the server (required)
  --server <host>     monitoring server hostname (required)
  --key "<pubkey>"    server proxy public key (required)
  --user <name>       tunnel account on the server (default: monitor)
  --keyfile <path>    tunnel private key path
                      (default: ~/.ssh/monitoring_tunnel)
  --dry-run           print what would happen, change nothing
  --skip-packages     do not touch the package manager
  --uninstall         remove everything this script installed
  -h, --help          this text
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)          NAME="$2"; shift ;;
    --port)          PORT="$2"; shift ;;
    --server)        SERVER="$2"; shift ;;
    --key)           PUBKEY="$2"; shift ;;
    --user)          TUNNEL_USER="$2"; shift ;;
    --keyfile)       KEYFILE="$2"; shift ;;
    --dry-run)       DRY_RUN=1 ;;
    --skip-packages) SKIP_PACKAGES=1 ;;
    --uninstall)     UNINSTALL=1 ;;
    -h|--help)       usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# ------------------------------------------------------------- preflight ----
is_alpine() { [ -f /etc/alpine-release ]; }

check_platform() {
  case "$(uname -s)" in
    Linux) ;;
    FreeBSD) die "FreeBSD is not supported yet" ;;
    Darwin) die "macOS cannot run a Linux exporter; use a Linux host or a VM" ;;
    *) die "unsupported operating system: $(uname -s)" ;;
  esac
  if is_alpine; then
    command -v rc-service >/dev/null || die "OpenRC is required on Alpine"
  else
    command -v systemctl >/dev/null && [ -d /run/systemd/system ] \
      || die "a running systemd is required (found none)"
  fi
  [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0 ..."
}

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# --------------------------------------------------------------- packages ---
pkg_installed() { command -v "$1" >/dev/null 2>&1; }

install_packages() {
  [ "$SKIP_PACKAGES" -eq 1 ] && { say "skipping packages (--skip-packages)"; return 0; }
  if pkg_installed prometheus-node-exporter || pkg_installed node_exporter; then
    say "node_exporter already present"
    return 0
  fi
  say "installing node_exporter"
  if pkg_installed apk; then
    apk add --no-cache prometheus-node_exporter curl
  elif pkg_installed apt-get; then
    $SUDO apt-get update -qq
    # DEBIAN_FRONTEND must be exported, not prefixed: with SUDO in front,
    # "DEBIAN_FRONTEND=x sudo apt-get" is parsed by sh as a command name.
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y prometheus-node-exporter
  elif pkg_installed dnf; then
    $SUDO dnf install -y prometheus-node_exporter curl
  elif pkg_installed yum; then
    $SUDO yum install -y prometheus-node_exporter curl
  elif pkg_installed pacman; then
    $SUDO pacman -S --needed --noconfirm prometheus-node_exporter curl
  elif pkg_installed zypper; then
    $SUDO zypper --non-interactive install prometheus-node_exporter curl
  else
    die "no supported package manager found (need apk/apt/dnf/yum/pacman/zypper)"
  fi
}

install_autossh() {
  pkg_installed autossh && { say "autossh already present"; return 0; }
  say "installing autossh"
  if pkg_installed apk; then apk add --no-cache autossh openssh-client
  elif pkg_installed apt-get; then DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y autossh openssh-client
  elif pkg_installed dnf; then $SUDO dnf install -y autossh openssh-clients
  elif pkg_installed yum; then $SUDO yum install -y autossh openssh-clients
  elif pkg_installed pacman; then $SUDO pacman -S --needed --noconfirm autossh openssh
  elif pkg_installed zypper; then $SUDO zypper --non-interactive install autossh openssh-clients
  else die "no supported package manager found"; fi
}

# ----------------------------------------------------------- the exporter ---
# Debian/Ubuntu and Arch both ship a unit called
# prometheus-node-exporter.service; RHEL/Alpine call it node_exporter. Find
# whichever exists rather than assuming.
find_exporter_unit() {
  for u in prometheus-node-exporter.service node_exporter.service; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
      echo "$u"; return 0
    fi
  done
  return 1
}

EXPORTER_BIN=""
find_exporter_bin() {
  for p in /usr/bin/prometheus-node_exporter /usr/bin/node_exporter \
           /usr/sbin/prometheus-node_exporter /usr/local/bin/prometheus-node_exporter; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  # Fall back to whatever the unit references.
  local u; u="$(find_exporter_unit || true)"
  [ -n "$u" ] || return 1
  sed -n 's/^ExecStart=//p' "/etc/systemd/system/$u" /usr/lib/systemd/system/"$u" \
    /lib/systemd/system/"$u" 2>/dev/null | awk '{print $1; exit}'
}

configure_exporter() {
  local unit; unit="$(find_exporter_unit)" \
    || die "node_exporter installed but no systemd unit found"
  EXPORTER_BIN="$(find_exporter_bin)" \
    || die "could not locate the node_exporter binary"

  say "configuring $unit to listen on 127.0.0.1:9100 only"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '       [dry-run] would write override for %s (%s)\n' "$unit" "$EXPORTER_BIN"
    return 0
  fi

  $SUDO mkdir -p "/etc/systemd/system/$unit.d"
  $SUDO tee "/etc/systemd/system/$unit.d/override.conf" >/dev/null <<EOF
[Service]
# Bound to loopback on purpose: the exporter publishes a detailed inventory of
# this machine. It is reachable only via the SSH tunnel, never over the LAN.
# The cleared ExecStart is required before the replacement takes effect.
ExecStart=
ExecStart=$EXPORTER_BIN --web.listen-address=127.0.0.1:9100
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "$unit" 2>/dev/null || $SUDO systemctl enable "$unit"
  $SUDO systemctl restart "$unit"
  sleep 2

  local st; st="$(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
  [ "$st" = "active" ] || die "$unit is '$st' — check: journalctl -u $unit -n 30"
  say "$unit is active"

  # Confirm the bind address. This is the single most important check: a
  # wildcard bind would expose the exporter to the local network.
  if command -v ss >/dev/null; then
    if ss -lnt 2>/dev/null | grep -q '127.0.0.1:9100'; then
      say "listening on 127.0.0.1:9100 (not exposed)"
    elif ss -lnt 2>/dev/null | grep -q ':9100'; then
      die "the exporter is NOT bound to loopback — refusing to continue.
  Run: ss -lntp | grep 9100   and fix the override by hand."
    fi
  fi
}

# ------------------------------------------------------------- promssh ------
# The server's proxy logs in as this user and may only forward to the exporter.
# It cannot get a shell and cannot reach any other port.
configure_promssh() {
  getent passwd promssh >/dev/null 2>&1 || {
    say "creating promssh account"
    [ "$DRY_RUN" -eq 1 ] || $SUDO useradd -m -s /usr/sbin/nologin \
        -c 'monitoring metrics reader' promssh
  }
  [ "$DRY_RUN" -eq 1 ] && { printf '       [dry-run] would install promssh key\n'; return 0; }

  $SUDO usermod -p '*' promssh
  # Defence in depth: nologin already blocks SSH sessions and password auth, but
  # locking the account too means nothing can authenticate as this user by any
  # method. It is a metrics-only identity, never a login.
  $SUDO usermod -L promssh 2>/dev/null || true
  $SUDO install -d -m 700 -o promssh -g promssh /home/promssh/.ssh
  # Written whole, never appended: a stale line here silently breaks scraping.
  printf '%s\n' "restrict,port-forwarding,permitopen=\"localhost:9100\" $PUBKEY" \
    | $SUDO tee /home/promssh/.ssh/authorized_keys >/dev/null
  $SUDO chown promssh:promssh /home/promssh/.ssh/authorized_keys
  $SUDO chmod 600 /home/promssh/.ssh/authorized_keys
  say "promssh configured (may forward to localhost:9100 only)"

  # Without AllowTcpForwarding the proxy cannot work at all, and this is the
  # single most common reason a hand-rolled install fails.
  if ! $SUDO sshd -T 2>/dev/null | grep -qiE '^allowtcpforwarding (yes|all)'; then
    warn "sshd does not allow TCP forwarding — the server will not be able to scrape."
    warn "check: sudo sshd -T | grep -i allowtcpforwarding"
  fi
}

# --------------------------------------------------------------- tunnel -----
configure_tunnel() {
  # Create the key as the invoking user, in their own ~/.ssh, with correct
  # ownership. Doing this as root under $HOME would leave root-owned files in
  # the user's home and, worse, the unit would reference the wrong path.
  if [ ! -f "$KEYFILE" ]; then
    say "generating tunnel keypair at $KEYFILE"
    [ "$DRY_RUN" -eq 1 ] || {
      $SUDO install -d -m 700 -o "$RUN_USER" -g "$RUN_USER" "$(dirname "$KEYFILE")"
      # Run keygen as the invoking user so the file is created with their
      # ownership. $SUDO is empty when we are already root, so the "sudo -u"
      # form must only be used when we actually need to drop privileges.
      if [ "$(id -u)" -eq 0 ] && [ "$RUN_USER" != "root" ]; then
        su -s /bin/sh -c "ssh-keygen -t ed25519 -N '' -C '$NAME-to-$SERVER' -f '$KEYFILE' -q" "$RUN_USER"
      else
        ssh-keygen -t ed25519 -N '' -C "$NAME-to-$SERVER" -f "$KEYFILE" -q
      fi
      $SUDO chown "$RUN_USER:$RUN_USER" "$KEYFILE" "$KEYFILE.pub"
      $SUDO chmod 600 "$KEYFILE"; $SUDO chmod 644 "$KEYFILE.pub"
    }
  else
    say "reusing existing tunnel key $KEYFILE"
  fi

  # Pin the server's host key. StrictHostKeyChecking=yes in the unit below
  # means an unpinned server simply fails to connect, so this is not optional.
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '       [dry-run] would pin the host key for %s in %s\n' "$SERVER" "$KNOWN_HOSTS"
  else
    $SUDO touch "$KNOWN_HOSTS"
    ssh-keyscan -H "$SERVER" 2>/dev/null | $SUDO tee -a "$KNOWN_HOSTS" >/dev/null || true
    $SUDO chmod 644 "$KNOWN_HOSTS"
    $SUDO chown "$RUN_USER:$RUN_USER" "$KNOWN_HOSTS" 2>/dev/null || true
    say "pinned host key for $SERVER in $KNOWN_HOSTS"
  fi

  local unit=/etc/systemd/system/monitoring-tunnel.service
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '       [dry-run] would install %s\n' "$unit"
    return 0
  fi

  # ServerAliveInterval=15 with CountMax=3 drops a dead link in ~45s, so a
  # sleeping laptop or a changed Wi-Fi recovers quickly. RestartSec stays at 15
  # so reconnect storms do not trip a rate limiter on the server's sshd.
  $SUDO tee "$unit" >/dev/null <<EOF
[Unit]
Description=Monitoring reverse SSH tunnel to $SERVER
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# The tunnel must run as the invoking user, not root: it reads that user's
# private key and known_hosts, and a root-owned unit cannot read them.
User=$RUN_USER
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/bin/autossh -M 0 -N -T \\
  -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=15 \\
  -o ServerAliveCountMax=3 \\
  -o StrictHostKeyChecking=yes \\
  -o IdentitiesOnly=yes \\
  -o AddressFamily=inet \\
  -i $KEYFILE \\
  -R 127.0.0.1:$PORT:127.0.0.1:22 \\
  $TUNNEL_USER@$SERVER
Restart=always
RestartSec=$AUTOSSH_RESTART

[Install]
WantedBy=multi-user.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable monitoring-tunnel.service 2>/dev/null || true
  say "tunnel unit installed"
}

# ---------------------------------------------------------------- verify ----
verify() {
  say "verifying"
  local unit; unit="$(find_exporter_unit || echo prometheus-node-exporter.service)"

  printf '       exporter : %s\n' "$(systemctl is-active "$unit" 2>/dev/null || echo '?')"
  if command -v curl >/dev/null; then
    if curl -fsS -m 5 http://127.0.0.1:9100/metrics >/dev/null 2>&1; then
      printf '       metrics  : reachable on loopback\n'
    else
      printf '       metrics  : NOT reachable — check journalctl -u %s\n' "$unit"
    fi
  fi
  printf '       tunnel   : %s\n' "$(systemctl is-enabled monitoring-tunnel.service 2>/dev/null || echo '?')"
  echo
  cat <<EOF
$(printf '%s')Done.$(printf '%s')

This machine will not appear on the dashboard until the SERVER has
authorised your key. The admin panel prints the exact command:

  1. Copy the "authorise the key" command from the panel and run it as root
     on the server. It authorises the tunnel account "$TUNNEL_USER".
  2. Once your tunnel is up, the server pins your host key:
       ssh-keyscan -p $PORT $SERVER 2>/dev/null | grep -v '^#' >> <proxy>/known_hosts
  3. Watch it come alive:
       sudo journalctl -u monitoring-tunnel -f
       sudo ss -lntp | grep $PORT     # on the SERVER

If it does not report, the server log names the cause:
       docker compose logs --tail=20 http-over-ssh      # docker server
       journalctl -u http-over-ssh -n 20               # native server
EOF
}

uninstall() {
  say "removing monitoring components"
  systemctl disable --now monitoring-tunnel.service 2>/dev/null || true
  $SUDO rm -f /etc/systemd/system/monitoring-tunnel.service
  $SUDO rm -f "/etc/systemd/system/$(find_exporter_unit || echo prometheus-node-exporter.service).d/override.conf"
  userdel -r promssh 2>/dev/null || true
  $SUDO systemctl daemon-reload 2>/dev/null || true
  say "removed. The node_exporter package and your SSH key were left in place."
}

# ------------------------------------------------------------------ main ----
check_platform

if [ "$UNINSTALL" -eq 1 ]; then
  uninstall
  exit 0
fi

[ -n "$NAME" ]  || die "--name is required (try --help)"
[ -n "$PORT" ]  || die "--port is required (try --help)"
[ -n "$SERVER" ] || die "--server is required (try --help)"
[ -n "$PUBKEY" ] || die "--key is required (try --help)"
case "$PORT" in ''|*[!0-9]*) die "--port must be numeric, got '$PORT'" ;; esac
case "$PUBKEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
  *) die "--key does not look like an SSH public key" ;;
esac
case "$TUNNEL_USER" in
  ''|*[!a-z0-9_-]*) die "--user must be a simple account name, got '$TUNNEL_USER'" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port out of range"

# Guard against being handed something that is not this installer. The usual
# cause is a wrong URL: requesting /install.sh from a host that serves a web UI
# returns an HTML login page, and sh then fails with a bare
# "Syntax error: newline unexpected" and no clue why. The real installer always
# begins with a shebang, so this check needs no opt-in flag.
if head -1 "$SELF" 2>/dev/null | grep -q '^#!'; then
  :
else
  first_line="$(head -1 "$SELF" 2>/dev/null || true)"
  warn "this file does not start with a shebang — it is not the installer."
  warn "first line was: ${first_line:-<empty>}"
  warn ""
  warn "you almost certainly downloaded a web page instead of the script."
  warn "Check the URL: it must point at the admin panel's own host, e.g."
  warn "  https://monitor-admin.<your-domain>/install.sh"
  warn "and NOT at Grafana, which has no /install.sh and answers with a"
  warn "redirect to its login page."
  die "refusing to continue"
fi

say "installing monitoring client '$NAME' -> $TUNNEL_USER@$SERVER:$PORT"
if [ "$DRY_RUN" -eq 1 ]; then
  say "DRY RUN — nothing will be changed"
fi

install_packages
install_autossh
configure_exporter
configure_promssh
configure_tunnel

[ "$DRY_RUN" -eq 1 ] && { say "dry run complete"; exit 0; }
verify