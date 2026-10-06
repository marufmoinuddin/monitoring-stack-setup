#!/bin/sh
# SSH ForceCommand for the restricted `monitor` account.
#
# Note on tunnels: sshd only runs ForceCommand for *session* channels (exec,
# shell, subsystem). A client that connects with `ssh -N` and only asks for a
# reverse forward requests no session at all, so this script is never invoked and
# the tunnel is unaffected. That is why a single ForceCommand can serve both
# purposes without interfering with forwarding.
#
# When it IS invoked, the only thing we accept is enrolment. Anything else — a
# shell, an arbitrary command — is refused.
set -eu

case "${1:-}" in
  -enrol|--enrol)
    # Runs as root: it writes monitor's authorized_keys, known_hosts and
    # prometheus.yml, then reloads ssh and Prometheus.
    exec /usr/local/bin/monitoring-admin -enrol
    ;;
  *)
    echo "This account is limited to monitoring tunnels and enrolment." >&2
    echo "If you are enrolling, the command must be: -enrol" >&2
    exit 1
    ;;
esac