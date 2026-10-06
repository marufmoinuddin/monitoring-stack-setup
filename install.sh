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
# SSH_HOST is where the tunnel actually connects. It defaults to --server, but
# you can point it at an IP when the hostname has a broken AAAA record.
SSH_HOST=""
# TUNNEL_HOST is the address the reverse port binds on the server. In Docker
# mode that is the private bridge gateway; natively it is loopback.
TUNNEL_HOST="127.0.0.1"
# Enrolment: the client hands its own public key to the server through the
# tunnel, and the server does the rest. NO_ENROL is the escape hatch for a
# hand-managed install.
ENROL_TOKEN=""
NO_ENROL=0
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
  --ssh-host <host>   address the tunnel dials (default: --server).
                      Use this when the hostname has a broken AAAA record.
  --tunnel-host <ip>  address the reverse port binds on the server
                      (default: 127.0.0.1; Docker mode uses 172.30.0.1)
  --enrol-token <t>   enrolment token from the admin panel. With this, the
                      installer registers itself with the server over the tunnel
                      and you need do nothing else on the server.
  --no-enrol          do not self-enrol (for a hand-managed install)
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
    --ssh-host)      SSH_HOST="$2"; shift ;;
    --tunnel-host)   TUNNEL_HOST="$2"; shift ;;
    --enrol-token)   ENROL_TOKEN="$2"; shift ;;
    --no-enrol)      NO_ENROL=1 ;;
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
is_alpine() { [ -f "${ALPINE_RELEASE:-/etc/alpine-release}" ]; }

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

  # Identify the distribution now, so every later step knows which package
  # manager and package names to use. This must happen before any install.
  detect_distro
  # Referenced here as $SUDO only for symmetry; real work happens in pkg_install.
  : "$SUDO"
}

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# --------------------------------------------------------------- packages ---
pkg_installed() { command -v "$1" >/dev/null 2>&1; }

# Identify the distribution ONCE, up front, from /etc/os-release, and pick both
# the package manager and the correct package names from a table. Guessing names
# per-call is how the installer ended up asking Arch for
# "prometheus-node_exporter" and failing with "target not found".
#
#   distro      exporter package            autossh        ssh client
#   debian      prometheus-node-exporter   autossh        openssh-client
#   arch        prometheus-node-exporter   autossh        openssh
#   fedora      prometheus-node-exporter   autossh        openssh-clients
#   alpine      prometheus-node-exporter   autossh        openssh-client
#
# Note the Alpine name really does use an underscore in some releases; the
# fallback list below covers that rather than betting on one spelling.
DISTRO=""
PKG_MGR=""
PKG_EXPORTER=""
PKG_AUTOSSH=""
PKG_SSHCLIENT=""

# _osrel_field <file> <KEY> — read one KEY=value from an os-release-style file
# without sourcing it. Works whether the file is one pair per line or several
# pairs on one line, and strips surrounding quotes.
_osrel_field() {
  local file="$1" key="$2" val=""
  [ -r "$file" ] || return 0
  # One per line first, then fall back to a space-separated single line.
  val="$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1)"
  if [ -z "$val" ]; then
    val="$(sed -n "s/.*[[:space:]]${key}=//p" "$file" 2>/dev/null | head -1)"
  fi
  # Strip matching surrounding quotes, then any stray whitespace.
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

detect_distro() {
  local id="" like=""
  # OS_RELEASE exists so the test harness can point this at a fixture. It never
  # touches the real /etc/os-release.
  local osrel="${OS_RELEASE:-/etc/os-release}"
  if [ -r "$osrel" ]; then
    # Sourcing os-release defines NAME, ID, VERSION and friends. Several of
    # those collide with this script's own variables — most importantly NAME,
    # which is our device label. Sourcing straight into the global scope meant
    # a device got labelled "CachyOS Linux" because os-release said
    # NAME="CachyOS Linux". Parse the two fields we need instead.
    #
    # Real os-release files put one KEY=value per line, but accept a single
    # line with several pairs too so a compact fixture (and the odd minimal
    # /etc/os-release in a container) still works.
    id="$(_osrel_field "$osrel" ID)"
    like="$(_osrel_field "$osrel" ID_LIKE)"
  fi
  [ -f /etc/alpine-release ] && DISTRO="alpine"

  if [ -z "$DISTRO" ]; then
    case "$id" in
      debian|ubuntu|raspbian|devuan) DISTRO="debian" ;;
      arch|manjaro|endeavouros|cachyos|garuda) DISTRO="arch" ;;
      fedora|rhel|centos|rocky|alma|ol) DISTRO="fedora" ;;
      alpine) DISTRO="alpine" ;;
      opensuse*|sles|sled) DISTRO="suse" ;;
      void) DISTRO="void" ;;
      gentoo) DISTRO="gentoo" ;;
      *)
        # Fall back on ID_LIKE for derivatives that do not set a known ID.
        case "$like" in
          *debian*) DISTRO="debian" ;;
          *arch*)   DISTRO="arch" ;;
          *fedora*|*rhel*) DISTRO="fedora" ;;
          *alpine*) DISTRO="alpine" ;;
          *suse*)   DISTRO="suse" ;;
          *) DISTRO="unknown" ;;
        esac
        ;;
    esac
  fi

  case "$DISTRO" in
    debian)  PKG_MGR="apt-get" ;;
    arch)    PKG_MGR="pacman" ;;
    fedora)  if pkg_installed dnf; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi ;;
    alpine)  PKG_MGR="apk" ;;
    suse)    PKG_MGR="zypper" ;;
    void)    PKG_MGR="xbps-install" ;;
    gentoo)  PKG_MGR="emerge" ;;
    *)       PKG_MGR="unknown" ;;
  esac

  case "$DISTRO" in
    debian)  PKG_EXPORTER="prometheus-node-exporter"; PKG_SSHCLIENT="openssh-client" ;;
    arch)    PKG_EXPORTER="prometheus-node-exporter"; PKG_SSHCLIENT="openssh" ;;
    fedora)  PKG_EXPORTER="node_exporter";             PKG_SSHCLIENT="openssh-clients" ;;
    alpine)  PKG_EXPORTER="prometheus-node-exporter"; PKG_SSHCLIENT="openssh-client" ;;
    suse)    PKG_EXPORTER="prometheus-node_exporter"; PKG_SSHCLIENT="openssh-clients" ;;
    void)    PKG_EXPORTER="prometheus-node-exporter"; PKG_SSHCLIENT="openssh" ;;
    gentoo)  PKG_EXPORTER="dev-util/prometheus-node-exporter"; PKG_SSHCLIENT="net-misc/openssh" ;;
    *)       PKG_EXPORTER="prometheus-node-exporter"; PKG_SSHCLIENT="openssh-client" ;;
  esac
  PKG_AUTOSSH="autossh"

  # If the distro's own manager is not installed, fall back to whatever we can
  # find — but only among managers that actually exist. In tests (and on a host
  # where the detected manager is absent) this must not silently select the
  # manager of the machine running the tests.
  if [ "$PKG_MGR" != "unknown" ] && ! pkg_installed "$PKG_MGR"; then
    local found=""
    for m in apt-get dnf yum pacman apk zypper xbps-install emerge; do
      if pkg_installed "$m"; then found="$m"; break; fi
    done
    if [ -n "$found" ]; then
      PKG_MGR="$found"
    fi
  fi
}

# pkg_install <pkg> [extra...] — install via the detected manager.
pkg_install() {
  [ "$PKG_MGR" = "unknown" ] && return 1
  case "$PKG_MGR" in
    apt-get)
      $SUDO apt-get update -qq || return 1
      DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$@" || return 1
      ;;
    dnf)     $SUDO dnf install -y "$@" || return 1 ;;
    yum)     $SUDO yum install -y "$@" || return 1 ;;
    pacman)  $SUDO pacman -S --needed --noconfirm "$@" || return 1 ;;
    apk)     $SUDO apk add --no-cache "$@" || return 1 ;;
    zypper)  $SUDO zypper --non-interactive install "$@" || return 1 ;;
    xbps-install) $SUDO xbps-install -yS "$@" || return 1 ;;
    emerge)  $SUDO emerge "$@" || return 1 ;;
    *) return 1 ;;
  esac
  return 0
}

install_packages() {
  [ "$SKIP_PACKAGES" -eq 1 ] && { say "skipping packages (--skip-packages)"; return 0; }

  if pkg_installed prometheus-node-exporter || pkg_installed node_exporter; then
    say "node_exporter already present"
    return 0
  fi
  say "installing $PKG_EXPORTER (on $DISTRO via $PKG_MGR)"
  if pkg_install "$PKG_EXPORTER" curl; then
    return 0
  fi
  # Some releases ship the other spelling. Try it before giving up.
  local alt
  for alt in prometheus-node_exporter node_exporter; do
    [ "$alt" = "$PKG_EXPORTER" ] && continue
    say "$PKG_EXPORTER unavailable, trying $alt"
    if pkg_install "$alt"; then
      return 0
    fi
  done
  die "could not install node_exporter under any known package name on $DISTRO.
  Install it by hand, then re-run with --skip-packages. Try:
    $PKG_MGR ... $( [ "$DISTRO" = arch ] && echo 'pacman -S prometheus-node-exporter' || echo "$PKG_EXPORTER" )"
}

install_autossh() {
  if pkg_installed autossh; then
    say "autossh already present"
    return 0
  fi
  say "installing autossh"
  pkg_install "$PKG_AUTOSSH" || warn "could not install autossh automatically — install it and re-run"
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
  # "local" still permits reverse (-R) forwarding, which is all we use, so it
  # is fine. Only a hard "no" blocks us.
  _atf="$($SUDO sshd -T 2>/dev/null | grep -iE '^allowtcpforwarding' | head -1 | awk '{print $2}')"
  case "$_atf" in
    yes|all|remote|local) : ;;
    no|"")
      warn "sshd does not allow TCP forwarding (${_atf:-unknown}) — the server cannot scrape."
      warn "fix in /etc/ssh/sshd_config.d/:  AllowTcpForwarding yes"
      warn "then: sudo sshd -t && sudo systemctl reload ssh"
      ;;
    *)
      warn "unexpected AllowTcpForwarding value: $_atf" ;;
  esac
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
    # Pin the name the tunnel will actually dial. With StrictHostKeyChecking=yes
    # ssh compares the presented key against the entry for that exact host, so
    # pinning "$SERVER" while dialling "$SSH_HOST" would fail verification.
    ssh-keyscan -H "$SSH_HOST" 2>/dev/null | $SUDO tee -a "$KNOWN_HOSTS" >/dev/null || true
    $SUDO chmod 644 "$KNOWN_HOSTS"
    $SUDO chown "$RUN_USER:$RUN_USER" "$KNOWN_HOSTS" 2>/dev/null || true
    say "pinned host key for $SSH_HOST in $KNOWN_HOSTS"
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
# AddressFamily=inet is not optional. If the dashboard hostname carries a
  # stale AAAA record (DuckDNS and friends often publish a link-local address
  # like fe80::...), ssh will try IPv6 first and fail with
  # "connect to host <name> port 22: Connection refused" or "Invalid argument",
  # even though IPv4 works perfectly. Forcing inet removes that whole class of
# failure.
ExecStart=/usr/bin/autossh -M 0 -N -T \\
  -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=15 \\
  -o ServerAliveCountMax=3 \\
  -o StrictHostKeyChecking=yes \\
  -o IdentitiesOnly=yes \\
  -o AddressFamily=inet \\
  -i $KEYFILE \\
  -R $TUNNEL_HOST:$PORT:127.0.0.1:22 \\
  $TUNNEL_USER@$SSH_HOST
Restart=always
RestartSec=$AUTOSSH_RESTART

[Install]
WantedBy=multi-user.target
EOF

  $SUDO systemctl daemon-reload
  # Enable AND start. Enabling alone leaves the unit inactive until the next
  # boot, which looks identical to a broken install: the exporter is healthy
  # and nothing reports.
  $SUDO systemctl enable monitoring-tunnel.service 2>/dev/null || true
  $SUDO systemctl restart monitoring-tunnel.service
  sleep 3
  if [ "$(systemctl is-active monitoring-tunnel.service 2>/dev/null || echo inactive)" = "active" ]; then
    say "tunnel running"
    enrol_self
  else
    warn "the tunnel unit did not stay active — check:"
    warn "  sudo journalctl -u monitoring-tunnel -n 30"
    warn "the usual cause is that the server has not authorised your key yet."
  fi
}


# ------------------------------------------------------------- enrol -------
# Hand our public key to the server through the tunnel that is already open, and
# let the server add authorized_keys, pin our host key and add the Prometheus
# target. After this the device reports; there is nothing left for the operator
# to do on the server.
#
# We retry because the tunnel may still be coming up, and because the very first
# connection can race the server's own reload.
enrol_self() {
  [ "$NO_ENROL" -eq 1 ] && { say "skipped self-enrolment (--no-enrol)"; return 0; }
  if [ -z "$ENROL_TOKEN" ]; then
    say "no --enrol-token: skipping self-enrolment."
    c_note "the device will NOT report until the server is told about it."
    return 0
  fi

  local payload pubkey
  pubkey="$(cat "$KEYFILE.pub" 2>/dev/null || true)"
  [ -n "$pubkey" ] || { warn "cannot read $KEYFILE.pub — cannot enrol"; return 1; }

  # JSON-escape the pubkey comment defensively; it is our own hostname so it
  # should never need it, but a stray quote would produce invalid JSON.
  local esc
  esc="$(printf '%s' "$pubkey" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  payload=$(printf '{"token":"%s","device":"%s","port":%d,"pubkey":"%s","comment":"%s"}' \
      "$ENROL_TOKEN" "$NAME" "$PORT" "$esc" "$NAME-to-$SERVER")

  say "registering with the server over the tunnel"

  local attempt out rc connected=0
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    # The ForceCommand runs on the server and reads stdin, so we pipe the
    # payload in and read its reply from stdout.
    out="$(printf '%s' "$payload" | timeout 30 ssh -T \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=yes \
            -o IdentitiesOnly=yes \
            -o AddressFamily=inet \
            -o ExitOnForwardFailure=no \
            -i "$KEYFILE" \
            -p "$PORT" \
            "$TUNNEL_USER@$SERVER" 2>/dev/null)" && connected=1 || true

    if [ -n "$out" ]; then
      # The server replies with one JSON object. Pull out the message without
      # assuming jq is present.
      case "$out" in
        *'"ok":true'*)
          say "enrolled: $(printf '%s' "$out" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')"
          say "that is everything — this device will appear on the dashboard."
          return 0 ;;
        *)
          warn "server refused: $(printf '%s' "$out" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')"
          warn "raw reply: $out"
          return 1 ;;
      esac
    fi

    # No reply yet: most likely the tunnel is still establishing, or the server
    # has not yet reloaded the ForceCommand for our account.
    printf '       attempt %d/10 — no reply, waiting 10s\n' "$attempt"
    sleep 10
  done

  warn "could not reach the enrolment endpoint after 10 attempts."
  warn "check that the tunnel is up:  $SUDO journalctl -u monitoring-tunnel -n 20"
  warn "then re-run this installer, or enrol by hand on the server."
  return 1
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

$(printf '\033[1;33m')YOUR PUBLIC KEY -- the server needs exactly this line$(printf '\033[0m')

The tunnel keypair is generated HERE, on this machine, not on the server -- the
server has never seen it. Paste this single line on the server as root, into
the tunnel account's authorized_keys:

$( [ -f "$KEYFILE.pub" ] && sed 's/^/  /' "$KEYFILE.pub" || echo "  (could not read $KEYFILE.pub)" )

Then, on the server:

  1. pin this machine's host key (once the tunnel is up):
       ssh-keyscan -p $PORT $SERVER 2>/dev/null | grep -v '^#' >> <proxy-dir>/known_hosts
  2. add the target to Prometheus so it gets scraped:
       - targets: ['$TUNNEL_HOST:$PORT']
         labels:
           device: $NAME
     then reload Prometheus:  docker compose kill -s HUP prometheus

Watch it come alive:
  $SUDO journalctl -u monitoring-tunnel -f      # here, on the client
  ss -lntp | grep $PORT                          # on the server

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
# The tunnel dials SSH_HOST, which defaults to the dashboard host.
[ -n "$SSH_HOST" ] || SSH_HOST="$SERVER"
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
say "detected: $DISTRO ($PKG_MGR)"
if [ "$DISTRO" = "unknown" ]; then
  warn "unrecognised distribution; install packages manually and re-run with --skip-packages"
fi
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