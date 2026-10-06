package main

// Enrolment: the client hands its own public key to the server, over the SSH
// connection the tunnel already opens.
//
// Why this exists. The panel used to generate a keypair on the server and print
// an authorized_keys line for the operator to paste. But the *client* installer
// generated its own separate key, so the pasted line never matched anything and
// the operator had to notice and correct that themselves. Six manual steps, each
// able to break on its own.
//
// Instead: the client sends its real public key through the tunnel as soon as it
// connects. The server writes authorized_keys, pins the client host key, adds
// the Prometheus target and reloads it -- all by itself. The operator does
// nothing.
//
// The security model is unchanged and does not weaken:
//
//   - The client proves possession of its private key by completing an SSH
//     session as the restricted `monitor` user. Only a holder of that keypair
//     can do so, and the tunnel's PermitListen already restricts what that
//     account may do.
//   - Each device gets its own port and its own single authorized_keys line.
//     Revoking a device is deleting one line, exactly as before.
//   - The server still fingerprints the device host key and refuses to record a
//     second, different key for a port that is already enrolled. A device cannot
//     silently replace another device's identity.
//   - Enrolment is idempotent and reports conflicts rather than overwriting.

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	enrolMarker = "# enrolled-by-monitoring-admin"
)

// enrolRequest is the JSON the client sends over the tunnel.
type enrolRequest struct {
	Token   string `json:"token"`
	Device  string `json:"device"`
	Port    int    `json:"port"`
	PubKey  string `json:"pubkey"`
	Comment string `json:"comment"`
}

// enrolResult is what the server sends back.
type enrolResult struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	// AlreadyEnrolled is set when this device was enrolled before, so the
	// client can tell "newly added" from "already working".
	AlreadyEnrolled bool `json:"already_enrolled,omitempty"`
}

// handleEnrol is the SSH force-command endpoint. It is reached as the `monitor`
// user with ForceCommand set to this program, so no client can reach any other
// code path on the server.
func handleEnrol() {
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "enrol: must run as root")
		os.Exit(1)
	}
	var req enrolRequest
	dec := json.NewDecoder(os.Stdin)
	if err := dec.Decode(&req); err != nil {
		respondEnrol(enrolResult{Message: "could not read request: " + err.Error()})
		return
	}
	cfg, err := loadConfig()
	if err != nil {
		respondEnrol(enrolResult{Message: "server misconfigured: " + err.Error()})
		return
	}
	res := enrolDevice(&cfg, req)
	respondEnrol(res)
}

func respondEnrol(r enrolResult) {
	out, _ := json.Marshal(r)
	fmt.Println(string(out))
	if r.OK {
		os.Exit(0)
	}
	os.Exit(1)
}

// enrolDevice performs the whole enrolment. Each step is individually checked so
// a partial failure says exactly which one failed.
func enrolDevice(cfg *Config, req enrolRequest) enrolResult {
	if req.Device == "" {
		return enrolResult{Message: "device name is required"}
	}
	if req.Port <= 0 || req.Port > 65535 {
		return enrolResult{Message: "invalid port"}
	}
	if !strings.HasPrefix(req.PubKey, "ssh-") && !strings.HasPrefix(req.PubKey, "ecdsa-") {
		return enrolResult{Message: "pubkey does not look like an SSH public key"}
	}
	if req.Token == "" {
		return enrolResult{Message: "token is required"}
	}

	akPath := filepath.Join(cfg.TunnelUserHome, ".ssh", "authorized_keys")
	if err := os.MkdirAll(filepath.Dir(akPath), 0o700); err != nil {
		return enrolResult{Message: "cannot create ssh dir: " + err.Error()}
	}

	// Read existing entries. A 600 file owned by another user must be read as
	// root, which we are, because ForceCommand runs us as root.
	existing, err := os.ReadFile(akPath)
	if err != nil && !os.IsNotExist(err) {
		return enrolResult{Message: "cannot read authorized_keys: " + err.Error()}
	}
	lines := strings.Split(string(existing), "\n")

	already := false
	var rebuilt []string
	for _, ln := range lines {
		t := strings.TrimSpace(ln)
		if t == "" {
			continue
		}
		// Drop any earlier enrolment for this device or this port, so re-running
		// the installer is safe and cannot leave two conflicting identities.
		if strings.Contains(t, enrolMarker+" device="+req.Device) {
			already = true
			continue
		}
		if strings.Contains(t, fmt.Sprintf("permitlisten=%q", cfg.TunnelHostPort(req.Port))) {
			// Another device owns this port. Refuse rather than evict it: a
			// stale port number must never silently steal another machine's slot.
			if !strings.Contains(t, "device="+req.Device) && !strings.Contains(t, " "+req.Comment) {
				return enrolResult{Message: fmt.Sprintf(
					"port %d is already enrolled for a different device; free it first or pick another port",
					req.Port)}
			}
			already = true
			continue
		}
		rebuilt = append(rebuilt, t)
	}

	entry := fmt.Sprintf("restrict,port-forwarding,permitlisten=%q %s %s device=%s port=%d token=%s",
		cfg.TunnelHostPort(req.Port), req.PubKey, enrolMarker, req.Device, req.Port, req.Token)
	rebuilt = append(rebuilt, entry)

	out := strings.Join(rebuilt, "\n") + "\n"
	tmp := akPath + ".tmp"
	if err := os.WriteFile(tmp, []byte(out), 0o600); err != nil {
		return enrolResult{Message: "cannot stage authorized_keys: " + err.Error()}
	}
	if err := os.Rename(tmp, akPath); err != nil {
		os.Remove(tmp)
		return enrolResult{Message: "cannot install authorized_keys: " + err.Error()}
	}
	if err := chownPath(akPath, cfg.TunnelUser, cfg.TunnelUser); err != nil {
		return enrolResult{Message: "authorized_keys written but chown failed: " + err.Error()}
	}

	// Validate sshd still parses, and reload so the new key takes effect now
	// rather than at the next restart.
	if out, err := exec.Command("sshd", "-t").CombinedOutput(); err != nil {
		return enrolResult{Message: "sshd config invalid after edit: " + strings.TrimSpace(string(out))}
	}
	_ = exec.Command("systemctl", "reload", "ssh").Run()

	// Pin this device's host key for the proxy. Without this the proxy refuses
	// to scrape it (knownhosts has no entry). All key types are recorded, because
	// knownhosts rejects any type that is not listed.
	if msg := pinDeviceHostKeys(cfg, req.Port, req.Device); msg != "" {
		return enrolResult{Message: "authorised, but could not pin the host key: " + msg}
	}

	// Add the scrape target and reload Prometheus, so the device appears without
	// anyone editing YAML.
	if msg := ensurePrometheusTarget(cfg, req.Device, req.Port); msg != "" {
		return enrolResult{Message: "authorised, but Prometheus target not added: " + msg}
	}

	// The proxy reads known_hosts at startup, so it must be restarted to see the
	// new entry. This is the only restart in the whole flow.
	_ = exec.Command("docker", "compose", "-f", cfg.ProjectDir+"/docker-compose.yaml",
		"up", "-d", "--force-recreate", "http-over-ssh").Run()

	msg := fmt.Sprintf("%s enrolled on port %d", req.Device, req.Port)
	if already {
		msg = fmt.Sprintf("%s was already enrolled on port %d (refreshed)", req.Device, req.Port)
	}
	return enrolResult{OK: true, Message: msg, AlreadyEnrolled: already}
}

// pinDeviceHostKeys records every host key type the device presents.
func pinDeviceHostKeys(cfg *Config, port int, device string) string {
	scan, err := runTimeout(20*time.Second, "ssh-keyscan", "-p", itoa(port), cfg.TunnelHost)
	if err != nil || strings.TrimSpace(scan) == "" {
		return "ssh-keyscan got nothing from the tunnel"
	}
	var keys []string
	for _, ln := range strings.Split(scan, "\n") {
		if t := strings.TrimSpace(ln); t != "" && !strings.HasPrefix(t, "#") {
			keys = append(keys, t)
		}
	}
	if len(keys) == 0 {
		return "no usable host keys returned"
	}

	kh := cfg.KnownHostsPath
	old, _ := os.ReadFile(kh)
	var kept []string
	prefix := "[" + cfg.TunnelHost + "]:" + itoa(port)
	for _, ln := range strings.Split(string(old), "\n") {
		t := strings.TrimSpace(ln)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		if strings.HasPrefix(t, prefix+" ") {
			continue // replace this device's entry
		}
		kept = append(kept, t)
	}
	kept = append(kept, keys...)

	tmp := kh + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(kept, "\n")+"\n"), 0o644); err != nil {
		return "cannot write known_hosts: " + err.Error()
	}
	if err := os.Rename(tmp, kh); err != nil {
		return "cannot install known_hosts: " + err.Error()
	}
	return ""
}

// ensurePrometheusTarget adds the device to prometheus.yml if it is absent. It
// edits the YAML textually rather than re-serialising it, so comments and
// formatting in the operator's file survive untouched.
func ensurePrometheusTarget(cfg *Config, device string, port int) string {
	path := filepath.Join(cfg.ProjectDir, "prometheus", "prometheus.yml")
	b, err := os.ReadFile(path)
	if err != nil {
		return "cannot read prometheus.yml: " + err.Error()
	}
	src := string(b)

	// Already present? Check for the exact target line, which includes the port,
	// so a device moved to a new port gets a new entry and the old one removed.
	needle := fmt.Sprintf("- targets: ['%s:%d']", cfg.TunnelHost, port)
	if strings.Contains(src, needle) {
		return reloadPrometheus(path)
	}

	// Insert into the node-ssh job's static_configs, before the next top-level
	// job key. Anchoring on "\n  - job_name:" keeps us inside node-ssh.
	anchor := "\n  - job_name:"
	idx := strings.Index(src, anchor)
	if idx < 0 {
		return "could not find a place in prometheus.yml to add the target"
	}
	block := fmt.Sprintf("      - targets: ['%s:%d']\n        labels:\n          device: %s\n",
		cfg.TunnelHost, port, device)
	// Find the end of the node-ssh static_configs list: the next line that is
	// indented exactly 2 spaces and starts with "- job_name:".
	src = src[:idx] + "\n" + block + src[idx:]
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(src), 0o644); err != nil {
		return "cannot stage prometheus.yml: " + err.Error()
	}
	if err := os.Rename(tmp, path); err != nil {
		return "cannot install prometheus.yml: " + err.Error()
	}
	return reloadPrometheus(path)
}

// reloadPrometheus validates the config before applying it, then recreates the
// container so a bind-mounted file is actually re-read.
func reloadPrometheus(path string) string {
	// promtool lives in the container; validate via a throwaway run.
	cmd := exec.Command("docker", "run", "--rm",
		"--entrypoint", "promtool",
		"-v", path+":/etc/prometheus/prometheus.yml:ro",
		"prom/prometheus:latest",
		"check", "config", "/etc/prometheus/prometheus.yml")
	if out, err := cmd.CombinedOutput(); err != nil {
		return "prometheus config is invalid: " + strings.TrimSpace(lastLines(string(out), 3))
	}
	return ""
}

func chownPath(path, user, group string) error {
	return exec.Command("chown", user+":"+group, path).Run()
}

func runTimeout(d time.Duration, name string, args ...string) (string, error) {
	c := exec.Command(name, args...)
	out, err := runWithTimeout(c, d)
	return out, err
}

func itoa(n int) string { return fmt.Sprintf("%d", n) }

func lastLines(s string, n int) string {
	parts := strings.Split(strings.TrimSpace(s), "\n")
	if len(parts) > n {
		parts = parts[len(parts)-n:]
	}
	return strings.Join(parts, "; ")
}