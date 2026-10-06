# Grafana + Prometheus monitoring over SSH reverse tunnels

> Watch any number of Linux machines — laptops, home servers, anything behind
> NAT — from one Grafana dashboard, **without opening a single inbound port and
> without WireGuard or any VPN.**

Add a machine with one command. No server-side editing, no key copying, no
YAML. The client installs itself and registers over the tunnel it opens.

---

## Contents

- [How it works](#how-it-works)
- [Add a machine](#add-a-machine)
- [Install the server](#install-the-server)
- [Install the admin panel](#install-the-admin-panel)
- [The client installer](#the-client-installer)
- [What's in the repo](#whats-in-the-repo)
- [Deployment modes](#deployment-modes)
- [Security model](#security-model)
- [Operations](#operations)
- [Troubleshooting](#troubleshooting)
- [Design notes](#design-notes)
- [Traps this encodes](#traps-this-encodes)

---

## How it works

Most monitoring tools want you to expose a metrics port or trust a SaaS. An
exposed `/metrics` is a permanent, detailed readout of your kernel, disk layout
and service inventory — scanners find it within minutes. A hosted service sees
every machine's metadata and asks you to trust a third party.

This inverts it. Every client dials **out** and holds an SSH reverse tunnel
open. Nothing on the internet listens except nginx on 80/443.

```
     your browser
          │  HTTPS  ──or──  ssh -L (nothing public at all)
          ▼
       nginx  ── optional ──┐
          │                │
          ▼                │
   Grafana ────────────────┘
          │  internal network
          ▼
   Prometheus ──HTTP──► http-over-ssh (proxy)
                          │  SSH through the tunnel port
                          ▼
              reverse-tunnel listener on the server
                          ▲
                          │  opened OUTWARD by the client (autossh)
                          │
              client: sshd:22 ──► node_exporter (127.0.0.1:9100)
```

The proxy SSHes *into* the tunnel, authenticates as a restricted account, and
fetches the exporter. The exporter is bound to loopback, so even someone on the
same Wi-Fi cannot read it.

### Adding a machine is one command

```
   admin panel                      client
   ───────────                      ──────
   enter "my-laptop"
   reserve port 2201        ──►     paste one command
   mint an enrol token                     │
                                    installs node_exporter
                                    creates promssh
                                    generates its OWN key
                                    opens the tunnel
                                          │
   authorises the key      ◄──────────────┤  over the tunnel
   pins the host key        ◄──────────────┤
   adds the scrape target   ◄──────────────┘
   reloads ssh + Prometheus
```

The client sends its **own** public key through the tunnel it already has open.
The server does the rest. There is no step 2, and there is no key for you to
copy — an earlier design had the panel generate a key the client never used,
which forced a manual paste. That was the root cause of nearly all the friction
this design now removes.

## Add a machine

1. Open the panel at `https://monitor-admin.<your-domain>`.
2. Type a device name, click **Generate install command**.
3. Paste the command into a terminal on that machine.

That is the whole procedure. The device appears in the panel within about a
minute, once its first scrape completes.

The command looks like this — you never type it by hand:

```bash
curl -fsSL https://monitor-admin.example.com/install.sh -o /tmp/install-monitoring.sh \
  && head -1 /tmp/install-monitoring.sh | grep -q '^#!' \
  || { echo "ERROR: that URL returned a web page, not the installer."; exit 1; }; \
  chmod +x /tmp/install-monitoring.sh \
  && sudo /tmp/install-monitoring.sh --name my-laptop --port 2201 --user monitor \
       --server monitor.example.com --enrol-token 9f2c1a... --key "ssh-ed25519 AAAA..."
```

The `head -1 | grep -q '^#!'` guard matters: a web page saved as `install.sh`
cannot report its own problem, because `sh` parses its first line as a shell
redirection before any code runs.

## Install the server

Pick one. Both are idempotent — safe to re-run.

```bash
git clone https://github.com/marufmoinuddin/monitoring-stack-setup.git
cd monitoring-stack-setup

# Docker Compose
sudo ./monitoring-server-setup.sh --dry-run     # always read this first
sudo ./monitoring-server-setup.sh

# Native systemd — no Docker, no Go toolchain
sudo ./monitoring-server-setup-native.sh --dry-run
sudo ./monitoring-server-setup-native.sh
```

Each creates the restricted tunnel user, the sshd drop-in limiting it to three
reverse ports, per-port firewall rules, Prometheus, Grafana, the proxy, and a
client bundle.

Useful flags on both:

| Flag | Effect |
|---|---|
| `--dry-run` | print every action, change nothing |
| `--web nginx` | publish through nginx (default when one is found) |
| `--web none` | touch no web server; Grafana on loopback, reach it with `ssh -L` |
| `--rollback` | undo everything, keeping stored metrics |

With `--web none` there is no public URL at all:

```bash
ssh -L 3000:127.0.0.1:3000 <server>    # then browse http://127.0.0.1:3000
```

## Install the admin panel

The panel is what makes onboarding one command, so install it on any server
running the stack. It is a single static binary with no dependencies.

```bash
make check          # vet + build + a live 10-assertion smoke test
sudo make install   # /usr/local/bin/monitoring-admin
sudo install -m 644 monitoring-admin.service /etc/systemd/system/
sudo useradd -r -s /usr/sbin/nologin monitoring-admin
sudo install -d -o monitoring-admin -g monitoring-admin /var/lib/monitoring-admin
sudo install -d -m 755 /usr/local/share/monitoring
sudo install -m 644 install.sh /usr/local/share/monitoring/install.sh
sudo bash fix-admin-env.sh
sudo systemctl enable --now monitoring-admin
```

The server setup scripts already install the sshd drop-in pointing at
`/usr/local/libexec/monitoring-forcecommand.sh`, and publish `install.sh` to
`/usr/local/share/monitoring/`, so a fresh install needs only the panel binary
and its env file.

> **If you are upgrading an existing deployment**, check the drop-in. It must
> say `ForceCommand /usr/local/libexec/monitoring-forcecommand.sh` and the file
> must exist:
>
> ```bash
> sudo install -m 755 ssh-forcecommand.sh /usr/local/libexec/monitoring-forcecommand.sh
> sudo grep ForceCommand /etc/ssh/sshd_config.d/56-monitor-tunnel.conf
> sudo sshd -t && sudo systemctl reload ssh
> ```
>
> With `ForceCommand /usr/sbin/nologin` the client opens its tunnel, tries to
> enrol, and is refused — `nologin` answers every session channel. The installer
> retries and eventually says so, but the device will not report.

### Configure the panel

```bash
sudo bash fix-admin-env.sh      # writes /etc/monitoring/admin.env correctly
sudo systemctl enable --now monitoring-admin
```

> **Why the helper exists.** `MON_PROXY_PUBKEY` holds an SSH public key, which
> contains a space (`ssh-ed25519 AAAA…`). systemd's `EnvironmentFile=` splits
> assignments on whitespace, so a hand-written env file silently truncates the
> key to `ssh-ed25519` and turns its comment into a stray variable. The helper
> writes the key unquoted on one line, read from disk.

All panel settings are environment variables:

| Variable | Purpose |
|---|---|
| `MON_LISTEN` | listen address — see the note below |
| `MON_DOMAIN` | the hostname clients connect to |
| `MON_INSTALL_BASE` | where `install.sh` is served from (the panel's own host) |
| `MON_TUNNEL_HOST` | address client tunnels bind on the server |
| `MON_TUNNEL_USER` | tunnel account name (default `monitor`) |
| `MON_TUNNEL_USER_HOME` | that account's home |
| `MON_KNOWN_HOSTS` | the proxy's `known_hosts` file |
| `MON_PROJECT_DIR` | compose project dir, used for enrolment |
| `MON_PROMETHEUS_URL` | where to read scrape health |
| `MON_PROXY_PUBKEY` | the proxy's public key |
| `MON_STATE_DIR` | device database |
| `MON_REPO_DIR` | where `install.sh` is read from |

**`MON_LISTEN` needs care with containerised nginx.** A container's loopback is
itself, so nginx cannot reach a host service bound to `127.0.0.1`. Bind the
bridge gateway instead:

```bash
docker network inspect proxy_net --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
# -> 172.18.0.1
MON_LISTEN=172.18.0.1:8099
```

That address is not routable from outside, so nothing new is exposed.

### Publish the panel

```bash
sed 's/GATEWAY_IP/172.18.0.1/' monitor-admin.conf \
  > ~/docker/nginx/config/nginx/conf.d/monitor-admin.conf
docker exec nginx_proxy nginx -t && docker exec nginx_proxy nginx -s reload
```

Port 8099 is never opened in the firewall; nginx on 443 is the only way in. If
you would rather not publish it, skip the vhost and use
`ssh -L 8099:172.18.0.1:8099 <server>`.

**The panel has no authentication of its own.** It is behind whatever nginx
does. Put it behind the same protection as your other admin surfaces, restrict it
by source IP, or keep it on an SSH tunnel.

## The client installer

`install.sh` is deliberately **plain POSIX shell you can read before running**.
Nothing is downloaded except distro packages; no code is fetched at install
time.

It:

1. Identifies the distribution once and picks the right package names.
2. Installs `node_exporter` and **binds it to `127.0.0.1`**, then verifies the
   bind address. A wildcard bind would publish your disk layout and service
   inventory to the whole LAN.
3. Creates `promssh` — shell-less, password-locked, able to forward to
   `localhost:9100` and nothing else.
4. Generates a tunnel key **as the invoking user**, and pins the server host key.
5. Installs an `autossh` unit that survives sleep, reboots and Wi-Fi changes,
   forces IPv4, and starts rather than merely enabling.
6. Registers itself with the server over the tunnel and waits for confirmation.
7. Verifies its own work.

```
--name <name>       device label (required)
--port <n>          tunnel port on the server (required)
--server <host>     monitoring server hostname (required)
--key "<pubkey>"    server proxy public key (required)
--user <name>       tunnel account on the server (default: monitor)
--enrol-token <t>   enrolment token; with this you do nothing else
--no-enrol          do not self-enrol (hand-managed installs)
--ssh-host <host>   address the tunnel dials (default: --server)
--tunnel-host <ip>  address the reverse port binds on the server
--keyfile <path>    tunnel private key path
--dry-run           print what would happen, change nothing
--skip-packages     do not touch the package manager
--uninstall         remove everything this script installed
```

**Supported:** Debian/Ubuntu, Arch and derivatives (CachyOS, Manjaro),
Fedora/RHEL/Rocky, Alpine, openSUSE, Void, Gentoo. `test-detect-distro.sh`
covers 12 distributions plus a check that detection does not clobber the device
label.

## What's in the repo

| Path | What it is |
|---|---|
| `install.sh` | The client installer. POSIX `sh`, self-enrolling. |
| `admin/main.go` | The admin panel and `/api/*`. Standard-library-only Go. |
| `admin/enrol.go` | The enrolment endpoint the client calls over the tunnel. |
| `ssh-forcecommand.sh` | `ForceCommand` for the tunnel account: enrolment only. |
| `monitoring-admin.service` | systemd unit for the panel. |
| `monitor-admin.conf` | nginx vhost publishing the panel. |
| `monitoring-server-setup.sh` | Server setup, Docker Compose mode. |
| `monitoring-server-setup-native.sh` | Server setup, native systemd mode. |
| `monitoring-client-setup.sh` | Older bundle-based client path, kept for existing deployments. |
| `fix-admin-env.sh` | Rewrites the panel's env file so systemd does not truncate the key. |
| `test-detect-distro.sh` | 13 assertions over the distro/package table. |
| `Makefile` | `make build`, `make check`, `make test`, `make install`. |
| `docs/BESZEL-RESEARCH.md` | What was taken from Beszel, and what was not. |

Prefer the one-liner for new machines. `monitoring-client-setup.sh` remains for
hosts already deployed that way.

## Deployment modes

| | Docker Compose | Native systemd |
|---|---|---|
| Needs Docker | yes | **no** |
| Needs Go | yes (builds the proxy) | no (prebuilt, checksum-verified) |
| Config in | `~/docker/monitoring/` | `/etc/prometheus`, `/etc/http-over-ssh/` |
| Data in | named volumes | `/var/lib/monitoring` |
| Web server | optional | optional |

The client installer is identical either way — a client never needs to know how
the server is deployed.

## Security model

| Boundary | Control |
|---|---|
| Internet | Only nginx 80/443 is public. No compose service has a `ports:` section. |
| Tunnel ports | Loopback (native) or the private bridge address (Docker). Never public. |
| `monitor` account | Key-only, `nologin`, reverse forwarding only, capped by `PermitListen`. |
| `promssh` account | May forward to `localhost:9100` only. No shell, locked. |
| `node_exporter` | Bound to `127.0.0.1` — not even the local LAN can read it. |
| Host keys | Fingerprint-pinned both ways; a mismatch aborts without writing. |
| Tunnel keys | Generated on the client. The private half never leaves it. |
| Port takeover | A second key cannot claim a port that is already enrolled. |
| Revocation | Delete one line of `authorized_keys`, or click revoke. |

Enrolment does not weaken any of this. The client proves possession of its
private key by completing an SSH session as the restricted `monitor` user, and
`PermitListen` already caps what that account may do.

## Operations

```bash
# health
cd ~/docker/monitoring && docker compose ps
docker compose exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=up'

# native
systemctl status http-over-ssh prometheus grafana-server monitoring-admin

# add a scrape target after a manual change, then RELOAD PROPERLY
docker compose up -d --force-recreate prometheus

# why is a device down?
docker compose logs --tail=20 http-over-ssh
journalctl -u monitoring-tunnel -f        # on the client
```

### Dashboards

Import **1860** (Node Exporter Full), choose Prometheus, then pick the device in
the instance dropdown. The provisioned alerts are `DeviceDown`, `ProxyDown`,
`HighMemory`, `LowDisk` and `HighCPU`.

Prometheus cannot deliver notifications by itself — add a Grafana-managed
contact point if you want alerts delivered.

### Adding more devices

The panel allocates ports from `2201`–`2203`. For a fourth device, extend
`PermitListen` in the sshd drop-in, add a firewall rule, and raise
`MON_LAST_PORT`.

## Troubleshooting

The proxy log names the fault:

| Message | Meaning | Fix |
|---|---|---|
| `no SSH keys found` | key path wrong | check `HOS_KEY_DIR` |
| `open .../known_hosts` | proxy exited at startup | the file is mandatory |
| `connection refused` | no client tunnel yet | start the client's tunnel |
| `knownhosts: key is unknown` | not enrolled yet | wait, or re-run the installer |
| `knownhosts: key mismatch` | not all host key types pinned | see trap 3 |
| `unable to authenticate` | host keys fine, `promssh` key missing | re-run the installer |
| `SSH connection ... established` | success | — |

On the client, if the tunnel will not connect:

| Symptom | Cause |
|---|---|
| `Connection refused` on port 22, from your own IP | UFW's rate limiter blocked you; see trap 14 |
| `Invalid argument` / refused on IPv6 | a stale AAAA record; the unit forces IPv4 |
| `Permission denied (publickey)` | the server has not authorised this key |

## Design notes

What was taken from [Beszel](https://github.com/henrygd/beszel), which does
this better than the first version of this project did:

- **A readable installer.** Beszel serves 50 KB of POSIX shell, not a binary
  blob. You can read every byte before running it.
- **The public key in the command, not a secret.** Beszel's agent holds a key
  the hub verifies, so the install command leaks nothing.
- **Checksums first, verify before extract.**
- **A package-manager ladder** across distributions.
- **A panel that mints the command**, rather than documentation telling you to
  assemble one.

What was deliberately not copied: their WebSocket transport and Go hub. The SSH
tunnel here adds zero open ports and is already proven; replacing the transport
would be a rewrite, not an improvement. See `docs/BESZEL-RESEARCH.md`.

## Traps this encodes

Each was hit for real while building this, and each is handled in the code.

1. **UFW port ranges create no kernel rule.** `ufw allow … port 2201:2203`
   prints `Rule added` *and* stays listed in `ufw status`, but if the multiport
   extension is missing, `iptables-save` has nothing and traffic is blocked
   anyway. Ports are added individually and verified against the kernel.
2. **`kill -s HUP` reloads a stale bind-mounted file.** Editing `prometheus.yml`,
   the rules or `ssh/known_hosts` needs `up -d --force-recreate`.
3. **`knownhosts` rejects any unlisted key for a host it already knows.** A host
   offering rsa + ecdsa + ed25519 needs all three pinned.
4. **`http-over-ssh` has no key-file flag.** It reads keys *and* `known_hosts`
   from `$HOS_KEY_DIR` and exits if `known_hosts` is absent.
5. **`/boot/efi` reports ~100% full.** The `LowDisk` alert excludes `vfat`.
6. **A 600-owned file read as non-root returns empty**, which silently drops
   other devices' entries. Those reads use `sudo` and are verified.
7. **A "secure" cookie over plain HTTP breaks login.** `--web none` sets
   `cookie_secure = false`.
8. **`sudo $VAR=x cmd` is a parse error.** `DEBIAN_FRONTEND=… sudo apt-get` is
   right; `sudo DEBIAN_FRONTEND=… apt-get` is not.
9. **`sudo` resets `$HOME` to `/root`.** The installer resolves the real user
   from `$SUDO_USER`, or the tunnel unit references the wrong key and cannot
   authenticate.
10. **`curl -f` aborts on the 4xx you are asserting**, so a negative test passes
    for the wrong reason. Use `curl -sS`.
11. **A host service on `127.0.0.1` is invisible to containerised nginx.**
12. **Package names differ per distro.** Arch rejects
    `prometheus-node_exporter`. The distribution is detected once and names come
    from a table; `test-detect-distro.sh` asserts it across 12 distributions.
13. **A value with a space is silently split by `EnvironmentFile=`.** This
    truncated `MON_PROXY_PUBKEY` and made the panel emit the wrong URL for hours
    while the cause looked like something else.
14. **A reconnect loop rate-limits you out of port 22.** When a tunnel failed
    instantly, autossh retried every ~2s and UFW's `LIMIT` blocked your own IP,
    so a DNS problem presented as a dead port. Exempt a known client IP above
    the limit rule.
15. **Sourcing `os-release` clobbers your variables.** It defines `NAME`, which
    the installer also uses as the device label — so a device got labelled
    `CachyOS Linux`. Only `ID` and `ID_LIKE` are parsed now.

## Verified

- **13/13** distribution-detection assertions (`./test-detect-distro.sh`).
- **10/10** panel assertions (`make check`), including that the generated command
  self-enrols and leaves no manual server step.
- **End to end on a real Debian 12 VM** under libvirt/KVM: installer ran clean,
  exporter bound to loopback, tunnel opened, and the real `http-over-ssh` proxy
  scraped the VM through it, returning `nodename="mon-test"`.
- Three live machines reporting (two Arch-family laptops and the server itself),
  each identified from its own `node_uname_info`.

## License

MIT — see [LICENSE](LICENSE).

`http-over-ssh` is Copyright Ian Whiffin, used as a dependency. Native mode uses
the official v0.3.7 release binary and verifies its published SHA-256; Docker
mode pins the same commit when building from source.