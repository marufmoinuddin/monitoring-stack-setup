# Grafana + Prometheus monitoring over SSH reverse tunnels

> Monitor any number of Linux machines — laptops, home servers, anything behind
> NAT — from one Grafana dashboard, **without opening a single inbound port and
> without WireGuard or any VPN.**

Built as a replacement for Netdata Cloud: the same single-pane-of-glass view,
but your data never leaves your own server and no third party holds your host
keys.

## Two ways to deploy

Both are fully supported. Pick whichever fits the machine.

| | Docker Compose | Native systemd |
|---|---|---|
| **Server script** | `monitoring-server-setup.sh` | `monitoring-server-setup-native.sh` |
| Needs Docker | yes | **no** |
| Needs Go toolchain | yes (builds the proxy) | no (prebuilt binary) |
| Config lives in | `~/docker/monitoring/` | `/etc/prometheus`, `/etc/http-over-ssh/` |
| Services | 3 containers | 4 systemd units |
| Web server | optional nginx | optional nginx |
| Best for | VPSes already running containers | a plain server, a VPS you don't want to put containers on, Arch/Fedora boxes |

The **client script is the same for both** — a client never needs to know how
the server is deployed.

## Why this instead of the usual options

Most "monitor everything" tools want you to expose an endpoint to the internet
or join a SaaS. Both have costs:

- **Exposing a metrics port** hands an attacker a permanent, richly detailed
  readout of your kernel, disk layout and service inventory — and scanners find
  `/metrics` within minutes of a port appearing.
- **A hosted service** sees every machine's metadata and requires you to trust a
  third party that can be breached.

This inverts it. Every client dials **out** to your server and holds an SSH
reverse tunnel open. Nothing listens on the internet except nginx on 80/443.

```
     your browser
          │  HTTPS (or an SSH tunnel — your choice)
          ▼
       nginx  ─── or ───  nothing at all, Grafana on loopback
          │
          ▼
   Grafana  ──────────────┐
          │  internal network│
          ▼                │
   Prometheus ──HTTP──► http-over-ssh (proxy)
                          │  SSH to the tunnel port
                          ▼
              reverse-tunnel listener on the server
                          ▲
                          │  tunnel opened OUTWARD by the client (autossh)
                          │
              client: sshd:22 ──► node_exporter (127.0.0.1:9100)
```

The proxy SSHes *into* the tunnel, authenticates to the client, and fetches the
exporter. The client's exporter is bound to loopback, so even someone on the
same Wi-Fi cannot read it.

## Requirements

### Server

**Either** deployment needs: Linux with **systemd**, root/sudo, `curl`,
`ssh-keyscan`, and enough free disk for your retention window.

- **Docker mode** additionally needs Docker + Docker Compose.
- **Native mode** needs no container runtime at all. `prometheus` and
  `node_exporter` come from your distro; Grafana comes from Grafana's official
  package repository, which the script adds for you.

**A web server is optional.** By default the script uses nginx if it finds one
and writes a vhost. Pass `--web none` and it will not touch your web server at
all — Grafana then listens only on loopback and you reach it through an SSH
tunnel. Nothing is exposed to the internet in that mode.

If you *do* want nginx publishing, you need a hostname pointing at the server.
A TLS certificate is optional: with none found, the script writes a plain-HTTP
vhost and tells you.

### Client

Linux with systemd, `autossh`, `node_exporter`, and root/sudo. Nothing needs to
be reachable from the internet. No Docker, no VPN, no inbound firewall rule.

## Quick start

### Docker mode

```bash
git clone https://github.com/marufmoinuddin/monitoring-stack-setup.git
cd monitoring-stack-setup

# 1. On the SERVER — dry-run first, it changes nothing
sudo ./monitoring-server-setup.sh --dry-run
sudo ./monitoring-server-setup.sh              # add --web none to skip nginx

# 2. Copy the bundle and client script to your client
scp ~/docker/monitoring/client-bundle.env ./monitoring-client-setup.sh <client>:

# 3. On the CLIENT
chmod +x monitoring-client-setup.sh
./monitoring-client-setup.sh --bundle client-bundle.env --dry-run
./monitoring-client-setup.sh --bundle client-bundle.env --name my-laptop

# 4. Back on the SERVER — authorizes the key, waits for the tunnel,
#    pins the client's host key, restarts the proxy
sudo ./monitoring-server-setup.sh --add-client-key "ssh-ed25519 AAAA... my-laptop"
```

### Native mode

Identical, different script:

```bash
sudo ./monitoring-server-setup-native.sh --dry-run
sudo ./monitoring-server-setup-native.sh --web none     # or without --web for nginx

# bundle lands at /etc/http-over-ssh/client-bundle.env
scp /etc/http-over-ssh/client-bundle.env ./monitoring-client-setup.sh <client>:
```

### Then

Open Grafana, import dashboard **1860** (Node Exporter Full), pick Prometheus,
and choose your device in the instance dropdown.

Without a web server, forward the port instead:

```bash
ssh -L 3000:127.0.0.1:3000 <server>     # then browse http://127.0.0.1:3000
```

## The handoff file

The server writes `client-bundle.env` (mode 600) containing the server address,
its SSH host key fingerprint, the tunnel port, the proxy public key, and the
Grafana URL with credentials. The client script consumes exactly that file.

It is **parsed, never sourced** — values contain spaces and a bundle that
arrived over the network must not be able to execute code. The server's host
key is checked against the fingerprint in the bundle, and a mismatch aborts
without writing anything.

## Options

All three scripts accept `--dry-run`, `--yes`, and `--help`.

Server scripts:

| Flag | Effect |
|---|---|
| `--web nginx` | Publish through nginx (default when one is found) |
| `--web none` | No web server; Grafana on loopback, reach it via SSH tunnel |
| `--add-client-key "<key>"` | Phase 2: authorize a client, wait for its tunnel, pin its host key |
| `--rollback` | Undo everything (metrics data is kept) |

Docker server only: `--subnet`, `--domain`, `--grafana-host`, `--project`.

Native server only: `--domain`, `--grafana-host`, `--tunnel-host` (defaults to
`127.0.0.1`, so tunnels are loopback-only unless you widen it deliberately).

Client:

| Flag | Effect |
|---|---|
| `--bundle <file>` | The server bundle (auto-found in common paths if omitted) |
| `--name <name>` | Device label, used in the key comment and dashboards |
| `--no-unit` | Skip the autossh systemd unit |

## Adding more devices

One port, one key, one line per device. Ports `2201`-`2203` are pre-authorised.

```bash
./monitoring-client-setup.sh --bundle client-bundle.env --name pi
sudo ./monitoring-server-setup.sh --add-client-key "ssh-ed25519 AAAA... pi-to-monitoring-server"
```

Then add the target to `prometheus.yml` and restart **the server's** Prometheus.
Use `--force-recreate`, not `kill -s HUP` — see trap 2.

For a fourth device, extend `PermitListen` in the sshd drop-in and add another
firewall rule.

## How the security model holds

| Boundary | Control |
|---|---|
| Internet | Only nginx 80/443 is public. No compose service has a `ports:` section. |
| Tunnel ports | Bound to loopback (native) or the private bridge address (Docker). Never public. |
| `monitor` account | Key-only, `nologin`, reverse forwarding only, limited to three ports. |
| `promssh` account | May only forward to `localhost:9100`. No shell, no other ports. |
| `node_exporter` on clients | Bound to `127.0.0.1`, so not even the local LAN can read it. |
| Host keys | Fingerprint-pinned in both directions; mismatches abort. |
| Revocation | Delete one line of `authorized_keys`. |

## Troubleshooting

The proxy log narrows a fault precisely:

| Message | Meaning | Fix |
|---|---|---|
| `no SSH keys found` | key path wrong | check `HOS_KEY_DIR` and the `./ssh` mount (Docker) or `/etc/http-over-ssh` (native) |
| `open .../known_hosts: no such file` | proxy exited at startup | the file is mandatory — add a client |
| `connection refused` | no client tunnel yet | start the client's autossh service |
| `knownhosts: key is unknown` | no entry for that endpoint | run `--add-client-key` |
| `knownhosts: key mismatch` | not all host key types pinned | see trap 3 |
| `unable to authenticate` | host keys fine, `promssh` key missing | re-run the client script |
| `SSH connection ... established` | success | — |

Verify a working install:

```bash
# Docker
cd ~/docker/monitoring && docker compose ps
docker compose exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=up'

# Native
systemctl status http-over-ssh prometheus grafana-server
curl -s http://127.0.0.1:9090/api/v1/query?query=up
```

## Traps this encodes

Each was hit for real while building this, and each is handled in the scripts:

1. **UFW port ranges silently create no kernel rule.** `ufw allow ... port
   2201:2203 proto tcp` prints `Rule added` *and* stays listed in `ufw status`,
   but if the multiport extension is missing, `iptables-save` has nothing and
   traffic is blocked anyway. Both scripts add ports individually.
2. **`kill -s HUP` reloads a stale bind-mounted file.** In Docker mode, editing
   `prometheus.yml`, the rules, or `ssh/known_hosts` needs
   `docker compose up -d --force-recreate <svc>`.
3. **`knownhosts` rejects any unlisted key for a host it already knows.** A host
   offering rsa + ecdsa + ed25519 needs all three pinned, or you get
   `key is unknown` then `key mismatch`.
4. **`http-over-ssh` has no key-file flag.** It reads keys *and* `known_hosts`
   from `$HOS_KEY_DIR` and exits if `known_hosts` is absent, so
   `HOS_KEY_DIR=/ssh` is mandatory in Docker and `HOS_KEY_DIR=/etc/http-over-ssh`
   in native mode.
5. **`/boot/efi` reports ~100% full.** The `LowDisk` alert excludes `vfat`.
6. **A 600-owned file read as non-root returns empty.** The scripts use `sudo`
   for those reads and verify the merge kept every other device's entry.
7. **A "secure" cookie over plain HTTP breaks login.** In `--web none` mode the
   scripts set `cookie_secure = false`; otherwise the login loop never completes.

## Dashboards and alerts

Dashboard **1860** (Node Exporter Full) is the recommended starting point. The
provisioned alert rules are `DeviceDown`, `ProxyDown`, `HighMemory`, `LowDisk`
and `HighCPU`. Prometheus cannot send notifications by itself — add a
Grafana-managed contact point if you want alerts delivered.

## Security notes for contributors

- `client-bundle.env` and `.env` hold live credentials and are git-ignored. If
  you ever commit one, **rotate the Grafana password immediately** — assume it
  is public.
- Never hardcode a password, token, or private key. Generate secrets at install
  time, as both server scripts do.
- Keep the subnet, ports, and paths configurable via flags or environment
  variables rather than editing them into the scripts.
- Prefer `--web none` if you do not need a public dashboard URL. It is strictly
  the safer default.

## License

MIT — see [LICENSE](LICENSE).

`http-over-ssh` is Copyright Ian Whiffin, used as a dependency. Native mode uses
the official v0.3.7 release binary and verifies its published SHA-256; Docker
mode pins the same commit when building from source.