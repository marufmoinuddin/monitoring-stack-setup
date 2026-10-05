# Grafana + Prometheus monitoring over SSH reverse tunnels

> Monitor any number of Linux machines — laptops, home servers, anything behind
> NAT — from one Grafana dashboard, **without opening a single inbound port and
> without WireGuard or any VPN.**

Built as a replacement for Netdata Cloud, and modelled on how
[Beszel](https://github.com/henrygd/beszel) makes installation a single
copy-paste.

## The one-liner

```bash
curl -fsSL https://monitor.example.com/install.sh -o /tmp/install-monitoring.sh \
  && chmod +x /tmp/install-monitoring.sh \
  && sudo /tmp/install-monitoring.sh --name my-laptop --port 2201 \
       --server monitor.example.com --key "ssh-ed25519 AAAA..."
```

You do not assemble that by hand. The admin panel mints it: enter a device
name, click **Generate install command**, copy it, run it on the client. The
panel then prints the one server-side command needed to authorise the key.

```
   admin panel (monitor-admin.example.com)
        |  enter a name -> mints keypair + one-liner + server steps
        v
   client: paste one-liner  ──►  node_exporter on 127.0.0.1
                                 autossh reverse tunnel out to the server
   server: paste 1 command   ──►  authorises the client's key
                                 pins its host key when the tunnel appears
```

## Why this instead of the usual options

- **Exposing a metrics port** hands an attacker a permanent, detailed readout of
  your kernel, disk layout and service inventory — scanners find `/metrics`
  within minutes of a port appearing.
- **A hosted service** sees every machine's metadata and requires you to trust a
  third party.

This inverts it. Every client dials **out** and holds an SSH reverse tunnel
open. Nothing listens on the internet except nginx on 80/443.

```
     your browser
          │  HTTPS (or an SSH tunnel — your choice)
          ▼
       nginx ─── or ─── nothing at all, Grafana on loopback
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

## Components

| Path | What it is |
|---|---|
| `install.sh` | The client installer. POSIX `sh`, ~420 lines, prints every step. |
| `admin/` | The admin panel. Standard-library-only Go, no dependencies. |
| `monitoring-admin.service` | systemd unit for the panel. |
| `monitoring-server-setup.sh` | Server setup, Docker Compose mode. |
| `monitoring-server-setup-native.sh` | Server setup, native systemd mode. |
| `monitoring-client-setup.sh` | Bundle-based client setup (the older path). |
| `Makefile` | `make build` / `make check` / `make install` for the panel. |
| `docs/BESZEL-RESEARCH.md` | What we took from Beszel, and what we deliberately did not. |

## Quick start

### 1. The server

Pick one:

```bash
# Docker Compose
sudo ./monitoring-server-setup.sh --dry-run
sudo ./monitoring-server-setup.sh                 # add --web none to skip nginx

# Native systemd — no Docker, no Go toolchain needed
sudo ./monitoring-server-setup-native.sh --dry-run
sudo ./monitoring-server-setup-native.sh
```

Both create the tunnel network/user, the sshd drop-in, per-port firewall rules,
Prometheus, Grafana, the proxy, and the client bundle. Add `--web none` and they
touch no web server at all — Grafana stays on loopback and you reach it with
`ssh -L 3000:127.0.0.1:3000 <server>`.

### 2. The admin panel

```bash
make check          # vet + build + a live 9-assertion smoke test
sudo make install   # /usr/local/bin/monitoring-admin
sudo install -m 644 monitoring-admin.service /etc/systemd/system/
sudo useradd -r -s /usr/sbin/nologin monitoring-admin
sudo install -d -o monitoring-admin -g monitoring-admin /var/lib/monitoring-admin
sudo install -d -m 700 /etc/monitoring
sudo tee /etc/monitoring/admin.env >/dev/null <<EOF
MON_LISTEN=127.0.0.1:8099
MON_DOMAIN=monitor.example.com
MON_TUNNEL_HOST=127.0.0.1
MON_PROMETHEUS_URL=http://127.0.0.1:9090
MON_PROXY_PUBKEY=$(cat /path/to/proxy/id_ed25519.pub)
MON_REPO_DIR=$(pwd)
EOF
sudo chmod 600 /etc/monitoring/admin.env
sudo systemctl enable --now monitoring-admin
```

Publish it through nginx on its own subdomain, or simply forward the port with
`ssh -L 8099:127.0.0.1:8099 <server>` — the panel is an internal tool and needs
no public URL.

### 3. Add a client

In the panel: enter a device name → **Generate install command** → copy it →
paste the "authorise the key" step onto the server. The client appears in the
device table as soon as its tunnel is up.

## The client installer

`install.sh` is deliberately **plain POSIX shell you can read before running**.
Nothing is downloaded except distro packages; no code is fetched from the
network at install time.

It:

1. Refuses unknown platforms and non-systemd hosts with an actionable message.
2. Installs `node_exporter` via a package-manager ladder
   (apk → apt → dnf → yum → pacman → zypper).
3. **Binds the exporter to `127.0.0.1`** and verifies the bind address. This is
   the single most important step: a wildcard bind would publish your disk
   layout and service inventory to the whole LAN.
4. Creates `promssh`, a metrics-only account that can forward to
   `localhost:9100` and nothing else. Shell-less, password-locked.
5. Generates a tunnel key **as the invoking user** and pins the server host key.
6. Installs an `autossh` unit that survives sleep, reboots and Wi-Fi changes.
7. Verifies its own work and tells you what happens next.

```
--name <name>       device label (required)
--port <n>          tunnel port on the server (required)
--server <host>     monitoring server hostname (required)
--key "<pubkey>"    server proxy public key (required)
--user <name>       tunnel account on the server (default: monitor)
--dry-run           print what would happen, change nothing
--skip-packages     do not touch the package manager
--uninstall         remove everything this script installed
```

## Security model

| Boundary | Control |
|---|---|
| Internet | Only nginx 80/443 is public. No compose service has a `ports:` section. |
| Tunnel ports | Bound to loopback (native) or the private bridge address (Docker). Never public. |
| `monitor` / `testmon` | Key-only, `nologin`, reverse forwarding only, limited to specific ports by `PermitListen`. |
| `promssh` | May only forward to `localhost:9100`. No shell, locked account. |
| `node_exporter` | Bound to `127.0.0.1`, so not even the local LAN can read it. |
| Host keys | Fingerprint-pinned in both directions; mismatches abort without writing. |
| Keys | The panel generates them; the private half never leaves the server. |
| Revocation | Delete one line of `authorized_keys`, or click revoke in the panel. |

## Deployment modes

| | Docker Compose | Native systemd |
|---|---|---|
| Needs Docker | yes | **no** |
| Needs Go | yes (builds the proxy) | no (prebuilt binary, checksum-verified) |
| Config in | `~/docker/monitoring/` | `/etc/prometheus`, `/etc/http-over-ssh/` |
| Web server | optional | optional |

The client installer is identical either way — a client never needs to know how
the server is deployed.

## Adding more devices

The panel allocates ports from `2201`–`2203` and refuses to over-allocate. For a
fourth device, extend `PermitListen` in the sshd drop-in, add a firewall rule,
and raise `MON_LAST_PORT`.

## Troubleshooting

The proxy log names the fault:

| Message | Meaning | Fix |
|---|---|---|
| `no SSH keys found` | key path wrong | check `HOS_KEY_DIR` |
| `open .../known_hosts: no such file` | proxy exited at startup | the file is mandatory |
| `connection refused` | no client tunnel yet | start the client's autossh service |
| `knownhosts: key is unknown` | no entry for that endpoint | authorise the client |
| `knownhosts: key mismatch` | not all host key types pinned | see trap 3 |
| `unable to authenticate` | host keys fine, `promssh` key missing | re-run the installer |
| `SSH connection ... established` | success | — |

```bash
# Docker server
cd ~/docker/monitoring && docker compose ps
docker compose exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=up'
docker compose logs --tail=20 http-over-ssh

# Native server
systemctl status http-over-ssh prometheus grafana-server monitoring-admin
journalctl -u http-over-ssh -n 20
```

## Traps this encodes

Each was hit for real while building this:

1. **UFW port ranges silently create no kernel rule.** `ufw allow ... port
   2201:2203` prints `Rule added` *and* stays listed in `ufw status`, but if the
   multiport extension is missing `iptables-save` has nothing and traffic is
   blocked anyway. Always add ports individually and verify against the kernel.
2. **`kill -s HUP` reloads a stale bind-mounted file.** In Docker mode, editing
   `prometheus.yml`, the rules or `ssh/known_hosts` needs
   `docker compose up -d --force-recreate <svc>`.
3. **`knownhosts` rejects any unlisted key for a host it already knows.** A host
   offering rsa + ecdsa + ed25519 needs all three pinned, or you get
   `key is unknown` then `key mismatch`.
4. **`http-over-ssh` has no key-file flag.** It reads keys *and* `known_hosts`
   from `$HOS_KEY_DIR` and exits if `known_hosts` is absent.
5. **`/boot/efi` reports ~100% full.** The `LowDisk` alert excludes `vfat`.
6. **A 600-owned file read as non-root returns empty.** Scripts use `sudo` for
   those reads and verify the merge kept every other device's entry.
7. **A "secure" cookie over plain HTTP breaks login.** `--web none` sets
   `cookie_secure = false`.
8. **`sudo $VAR=x cmd` is a parse error.** `DEBIAN_FRONTEND=noninteractive sudo
   apt-get …` is right; `sudo DEBIAN_FRONTEND=… apt-get` is not. Hit this on a
   real Debian VM.
9. **`sudo` resets `$HOME` to `/root`.** The installer resolves the invoking
   user via `SUDO_USER` so the tunnel unit references the right key path and
   runs as the right account. Without this the unit silently cannot authenticate.
10. **`curl -f` aborts on the 4xx you are asserting.** Use plain `curl -sS` for
    negative tests, or the assertion passes for the wrong reason.

## Verified end to end

The one-liner path was tested on a real Debian 12 VM (libvirt/KVM), not just
linted:

- installer runs clean on a fresh VM, exporter bound to `127.0.0.1:9100`
- `promssh` created, locked, `permitopen` restricted
- tunnel key owned by the invoking user, not root
- autossh unit active, tunnel listener present on the server
- **the real `http-over-ssh` proxy scraped the VM through the tunnel** and
  returned `nodename="mon-test"`, `Debian 6.1.187-1` — proving the whole chain
- panel minted the command, authorized the key, and the scrape succeeded

## License

MIT — see [LICENSE](LICENSE).

`http-over-ssh` is Copyright Ian Whiffin, used as a dependency. Native mode uses
the official v0.3.7 release binary and verifies its published SHA-256; Docker
mode pins the same commit when building from source.