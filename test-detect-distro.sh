#!/usr/bin/env bash
# Test the installer's distribution detection against synthetic os-release
# fixtures. It exercises the real functions extracted from install.sh, so the
# distro/package table cannot drift from the code without this failing.
#
# It never writes to /etc: detect_distro() honours OS_RELEASE and ALPINE_RELEASE,
# and pkg_installed() is stubbed so the test host's own package managers cannot
# leak into the result.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$HERE/install.sh"
PASS=0
FAIL=0

eval "$(awk '/^is_alpine\(\)/,/^}/'     "$INSTALLER")"
eval "$(awk '/^detect_distro\(\)/,/^}/' "$INSTALLER")"

# Simulate which managers exist on the machine under test.
FAKE_PKGS=""
pkg_installed() {
  case " $FAKE_PKGS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

check() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    printf '  PASS  %-10s %s\n' "$desc" "$got"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %-10s got "%s", want "%s"\n' "$desc" "$got" "$want"
    FAIL=$((FAIL+1))
  fi
}

# run_case <desc> <os-release body> <alpine:yes|no> <mgr> <want>
run_case() {
  local desc="$1" body="$2" alpine="$3" mgr="$4" want="$5"
  local rel="$TMPDIR_T/$desc-os-release"
  local alp="$TMPDIR_T/$desc-alpine-release"
  printf '%s\n' "$body" > "$rel"
  if [ "$alpine" = "yes" ]; then : > "$alp"; else rm -f "$alp"; fi

  DISTRO=""; PKG_MGR=""; PKG_EXPORTER=""; PKG_AUTOSSH=""; PKG_SSHCLIENT=""
  FAKE_PKGS="$mgr"
  OS_RELEASE="$rel" ALPINE_RELEASE="$alp" detect_distro
  check "$desc" "$want" "$DISTRO/$PKG_MGR/$PKG_EXPORTER"
}

echo "=== distro / package manager / exporter package ==="
run_case arch      'ID=arch' no  pacman       'arch/pacman/prometheus-node-exporter'
run_case cachyos   'ID=cachyos ID_LIKE=arch' no  pacman       'arch/pacman/prometheus-node-exporter'
run_case manjaro   'ID=manjaro ID_LIKE=arch' no  pacman       'arch/pacman/prometheus-node-exporter'
run_case ubuntu    'ID=ubuntu ID_LIKE=debian' no  apt-get      'debian/apt-get/prometheus-node-exporter'
run_case debian    'ID=debian' no  apt-get      'debian/apt-get/prometheus-node-exporter'
run_case raspbian  'ID=raspbian ID_LIKE=debian' no  apt-get      'debian/apt-get/prometheus-node-exporter'
run_case fedora    'ID=fedora' no  dnf          'fedora/dnf/node_exporter'
run_case rocky     'ID=rocky ID_LIKE="rhel centos fedora"' no  dnf          'fedora/dnf/node_exporter'
run_case alpine    'ID=alpine' no  apk          'alpine/apk/prometheus-node-exporter'
run_case suse      'ID=opensuse-tumbleweed' no  zypper       'suse/zypper/prometheus-node_exporter'
run_case void      'ID=void' no  xbps-install 'void/xbps-install/prometheus-node-exporter'
run_case gentoo    'ID=gentoo' no  emerge       'gentoo/emerge/dev-util/prometheus-node-exporter'

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1