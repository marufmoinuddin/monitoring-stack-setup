// monitoring-admin is the control panel for the monitoring stack.
//
// It mints one-line install commands for new clients, shows which targets are
// alive, and hands out per-device SSH public keys. It talks to Prometheus's HTTP
// API for health — no database, no framework, standard library only, so it
// builds anywhere with a Go toolchain and has nothing to keep patched.
//
// Routes:
//   GET    /                    panel UI (add client, list devices, health)
//   GET    /api/devices         list devices
//   POST   /api/devices         create a device -> key, port, copy command
//   DELETE /api/devices/{name}  revoke, returning the exact cleanup commands
//   GET    /api/status          JSON health summary
//   GET    /install.sh          client installer (served from disk)
//   GET    /latest-version      pinned client version string
//   GET    /healthz             liveness for reverse-proxy checks
package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Version is stamped into the panel footer and the install command.
const Version = "1.0.0"

type Config struct {
	Listen        string
	Domain        string
	TunnelHost    string
	InstallURL    string
	ProxyPubkey   string
	PrometheusURL string
	StateDir      string
	FirstPort     int
	LastPort      int
	RepoDir       string
	TunnelUser    string
	InstallBase   string
}

type Device struct {
	Name    string `json:"name"`
	Port    int    `json:"port"`
	PubKey  string `json:"pubkey"`
	Created string `json:"created"`
}

type Server struct {
	cfg     Config
	mu      sync.RWMutex
	devices []Device
	state   string
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	cfg := Config{
		Listen:        env("MON_LISTEN", "127.0.0.1:8099"),
		Domain:        env("MON_DOMAIN", "monitor.example.com"),
		TunnelHost:    env("MON_TUNNEL_HOST", "127.0.0.1"),
		InstallURL:    env("MON_INSTALL_URL", ""),
		ProxyPubkey:   env("MON_PROXY_PUBKEY", ""),
		PrometheusURL: env("MON_PROMETHEUS_URL", "http://127.0.0.1:9090"),
		StateDir:      env("MON_STATE_DIR", "/var/lib/monitoring-admin"),
		RepoDir:       env("MON_REPO_DIR", "/opt/monitoring-stack"),
		FirstPort:     envInt("MON_FIRST_PORT", 2201),
		LastPort:      envInt("MON_LAST_PORT", 2203),
		TunnelUser:    env("MON_TUNNEL_USER", "monitor"),
	}
	// The installer is served by THIS panel, so the download URL must be the
	// panel's own host. Deriving it from MON_DOMAIN is only a fallback: an
	// operator commonly sets MON_DOMAIN to the Grafana hostname, and pointing
	// clients at Grafana's /install.sh returns Grafana's login page HTML, which
	// then fails to execute as a shell script.
	cfg.InstallBase = env("MON_INSTALL_BASE", "https://monitor-admin."+cfg.Domain)
	if cfg.InstallURL == "" {
		cfg.InstallURL = cfg.InstallBase + "/install.sh"
	}

	if len(os.Args) > 1 && (os.Args[1] == "-version" || os.Args[1] == "--version") {
		fmt.Println("monitoring-admin " + Version)
		return
	}

	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		log.Fatalf("state dir: %v", err)
	}
	s := &Server{cfg: cfg, state: cfg.StateDir + "/devices.json"}
	s.load()
	log.Printf("monitoring-admin %s: %d device(s) loaded from %s", Version, len(s.snapshot()), s.state)

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/api/devices", s.handleDevices)
	mux.HandleFunc("/api/devices/", s.handleDeviceByName)
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/install.sh", s.handleInstallScript)
	mux.HandleFunc("/latest-version", s.handleLatestVersion)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           s.withHeaders(mux),
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("listening on %s (domain %s, prometheus %s)", cfg.Listen, cfg.Domain, cfg.PrometheusURL)
	log.Fatal(srv.ListenAndServe())
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

// ---------------------------------------------------------------- state ----

func (s *Server) load() {
	b, err := os.ReadFile(s.state)
	if err != nil {
		return
	}
	var devs []Device
	if json.Unmarshal(b, &devs) == nil {
		s.devices = devs
	}
}

func (s *Server) saveLocked(devs []Device) error {
	b, err := json.MarshalIndent(devs, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.state + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.state)
}

func (s *Server) snapshot() []Device {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Device, len(s.devices))
	copy(out, s.devices)
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// ------------------------------------------------------------- prometheus ---

type DeviceHealth struct {
	Device string `json:"device"`
	Up     bool   `json:"up"`
	Job    string `json:"job,omitempty"`
	Err    string `json:"error,omitempty"`
}

type promResponse struct {
	Status string `json:"status"`
	Data   struct {
		Result []struct {
			Metric map[string]string `json:"metric"`
			Value  []interface{}     `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

// fetchHealth asks Prometheus for up{} and reduces it to per-device health.
// A device we track but which Prometheus has never heard of is reported as
// down with a distinct message, so "no data" is not confused with "scrape failed".
func (s *Server) fetchHealth() map[string]DeviceHealth {
	out := map[string]DeviceHealth{}
	for _, d := range s.snapshot() {
		out[d.Name] = DeviceHealth{Device: d.Name, Up: false, Err: "not scraped yet"}
	}

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(s.cfg.PrometheusURL + "/api/v1/query?query=" + urlEncode("up"))
	if err != nil {
		for k, v := range out {
			v.Err = "prometheus unreachable"
			out[k] = v
		}
		return out
	}
	defer resp.Body.Close()
	var pr promResponse
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return out
	}
	for _, r := range pr.Data.Result {
		name := r.Metric["instance"]
		if name == "" {
			name = r.Metric["job"]
		}
		job := r.Metric["job"]
		up := false
		if len(r.Value) == 2 {
			if fmt.Sprint(r.Value[1]) == "1" {
				up = true
			}
		}
		h := DeviceHealth{Device: name, Up: up, Job: job}
		if up {
			h.Err = ""
		}
		out[name] = h
	}
	return out
}

func urlEncode(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_', r == '.', r == '~':
			b.WriteRune(r)
		default:
			b.WriteString(fmt.Sprintf("%%%02X", r))
		}
	}
	return b.String()
}

// ------------------------------------------------------------ device CRUD --

func (s *Server) handleDevices(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, map[string]any{"devices": s.snapshot(), "health": s.fetchHealth()})
	case http.MethodPost:
		s.createDevice(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// createDevice mints an SSH keypair on the SERVER, reserves the next port, and
// returns the install command plus the two things the operator must do on the
// server afterwards.
//
// Generating the key here (rather than on the client) is deliberate: it keeps
// the copy-paste to exactly one line, and the private key never leaves the box.
func (s *Server) createDevice(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSpace(r.URL.Query().Get("name"))
	if name == "" {
		http.Error(w, "missing ?name=", http.StatusBadRequest)
		return
	}
	if !validName(name) {
		http.Error(w, "name must be letters, digits, dash or underscore (max 32)", http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	for _, d := range s.devices {
		if d.Name == name {
			s.mu.Unlock()
			http.Error(w, "device already exists: "+name, http.StatusConflict)
			return
		}
	}
	port := s.nextPortLocked()
	if port == 0 {
		s.mu.Unlock()
		http.Error(w, fmt.Sprintf("no free port in %d-%d; extend PermitListen and the firewall first",
			s.cfg.FirstPort, s.cfg.LastPort), http.StatusConflict)
		return
	}

	keyDir := s.cfg.StateDir + "/keys"
	if err := os.MkdirAll(keyDir, 0o700); err != nil {
		s.mu.Unlock()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	keyPath := keyDir + "/" + name
	if _, err := os.Stat(keyPath); err == nil {
		s.mu.Unlock()
		http.Error(w, "key already exists for "+name, http.StatusConflict)
		return
	}
	cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-N", "", "-C", name+"-to-"+s.cfg.Domain, "-f", keyPath)
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		s.mu.Unlock()
		http.Error(w, "ssh-keygen failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	pubBytes, err := os.ReadFile(keyPath + ".pub")
	if err != nil {
		s.mu.Unlock()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	pub := strings.TrimSpace(string(pubBytes))

	d := Device{Name: name, Port: port, PubKey: pub, Created: time.Now().UTC().Format(time.RFC3339)}
	s.devices = append(s.devices, d)
	err = s.saveLocked(s.devices)
	s.mu.Unlock()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, map[string]any{
		"device":         d,
		"install_command": s.installCommand(name, port),
		"server_steps":   s.serverSteps(d),
	})
}

func (s *Server) nextPortLocked() int {
	used := map[int]bool{}
	for _, d := range s.devices {
		used[d.Port] = true
	}
	for p := s.cfg.FirstPort; p <= s.cfg.LastPort; p++ {
		if !used[p] {
			return p
		}
	}
	return 0
}

func validName(n string) bool {
	if len(n) == 0 || len(n) > 32 {
		return false
	}
	for _, r := range n {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
		default:
			return false
		}
	}
	return true
}

// installCommand is the one-liner. It mirrors Beszel's shape: fetch a readable
// script, then run it with the port, the proxy public key and the server URL.
//
// Two things here are load-bearing and both were learned the hard way:
//
//  1. The URL is THIS panel's own host, never Grafana. Grafana has no
//     /install.sh and answers with a redirect to its login page.
//  2. The download is validated before it is executed. A web page saved as
//     install.sh cannot self-guard: its first line begins with '<', which sh
//     parses as an input redirection and dies with "cannot open a" or
//     "Syntax error: newline unexpected" before any code runs. So the check
//     must happen in the command, not inside the script.
func (s *Server) installCommand(name string, port int) string {
	dl := s.cfg.InstallURL
	return fmt.Sprintf(
		"curl -fsSL %s -o /tmp/install-monitoring.sh && "+
			"head -1 /tmp/install-monitoring.sh | grep -q '^#!' || "+
			"{ echo \"ERROR: that URL returned a web page, not the installer.\"; "+
			"echo \"The admin panel must be published at https://monitor-admin.<your-domain>/\"; "+
			"head -2 /tmp/install-monitoring.sh; exit 1; }; "+
			"chmod +x /tmp/install-monitoring.sh && "+
			"sudo /tmp/install-monitoring.sh --name %s --port %d --user %s --server %s --key %q",
		dl, name, port, s.cfg.TunnelUser, s.cfg.Domain, s.cfg.ProxyPubkey,
	)
}

// serverSteps are the things only the operator can do, on the server.
func (s *Server) serverSteps(d Device) []string {
	return []string{
		fmt.Sprintf("sudo tee -a /home/monitor/.ssh/authorized_keys >/dev/null <<'EOF'\nrestrict,port-forwarding,permitlisten=\"%s:%d\" %s\nEOF",
			s.cfg.TunnelHost, d.Port, d.PubKey),
		fmt.Sprintf("sudo chmod 600 /home/monitor/.ssh/authorized_keys && sudo chown monitor:monitor /home/monitor/.ssh/authorized_keys"),
		fmt.Sprintf("# then pin the client host key once its tunnel is up:\n#   ssh-keyscan -p %d %s 2>/dev/null | grep -v '^#' >> %s", d.Port, s.cfg.TunnelHost, s.cfg.StateDir+"/known_hosts"),
	}
}

func (s *Server) handleDeviceByName(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/api/devices/")
	if name == "" {
		http.Error(w, "missing device name", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	var kept []Device
	found := false
	for _, d := range s.devices {
		if d.Name == name {
			found = true
			continue
		}
		kept = append(kept, d)
	}
	if !found {
		s.mu.Unlock()
		http.Error(w, "no such device", http.StatusNotFound)
		return
	}
	s.devices = kept
	err := s.saveLocked(kept)
	s.mu.Unlock()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	_ = os.Remove(s.cfg.StateDir + "/keys/" + name)
	_ = os.Remove(s.cfg.StateDir + "/keys/" + name + ".pub")
	writeJSON(w, map[string]any{
		"revoked": name,
		"server_steps": []string{
			fmt.Sprintf("# remove the line for %q from /home/monitor/.ssh/authorized_keys", name),
			fmt.Sprintf("# remove its target from prometheus.yml, then reload Prometheus"),
		},
	})
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{
		"version":    Version,
		"devices":    s.snapshot(),
		"health":     s.fetchHealth(),
		"prometheus": s.cfg.PrometheusURL,
	})
}

// ------------------------------------------------------- served endpoints --

func (s *Server) handleInstallScript(w http.ResponseWriter, r *http.Request) {
	path := s.cfg.RepoDir + "/install.sh"
	b, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, "installer not found at "+path, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/x-shellscript; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Write(b)
}

func (s *Server) handleLatestVersion(w http.ResponseWriter, r *http.Request) {
	// The installer resolves "latest" from here so a version bump needs no
	// change to the copy-pasted command.
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintln(w, Version)
}

// ------------------------------------------------------------------- UI ----

func (s *Server) withHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "same-origin")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	health := s.fetchHealth()
	data := struct {
		Version     string
		Domain      string
		Devices     []Device
		Health      map[string]DeviceHealth
		ProxyPubkey string
		PortRange   string
	}{
		Version:     Version,
		Domain:      s.cfg.Domain,
		Devices:     s.snapshot(),
		Health:      health,
		ProxyPubkey: s.cfg.ProxyPubkey,
		PortRange:   fmt.Sprintf("%d-%d", s.cfg.FirstPort, s.cfg.LastPort),
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := indexTmpl.Execute(w, data); err != nil {
		log.Printf("template: %v", err)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

const pageCSS = `
:root{--bg:#0b0f14;--panel:#121820;--line:#1e2733;--fg:#dce4ec;--dim:#8b9aad;
--ok:#3fb950;--bad:#f85149;--warn:#d29922;--accent:#58a6ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:14px/1.6 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.wrap{max-width:1000px;margin:0 auto;padding:32px 20px 80px}
h1{font-size:20px;margin:0 0 4px;letter-spacing:.3px}
h2{font-size:15px;margin:32px 0 12px;color:var(--dim);text-transform:uppercase;
letter-spacing:.12em;font-weight:600}
.sub{color:var(--dim);margin:0 0 8px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:10px;
padding:18px;margin-bottom:16px}
label{display:block;color:var(--dim);margin-bottom:6px;font-size:12px;
text-transform:uppercase;letter-spacing:.08em}
input{background:#0a0e13;border:1px solid var(--line);color:var(--fg);
padding:10px 12px;border-radius:6px;font:inherit;width:100%}
input:focus{outline:none;border-color:var(--accent)}
button{background:var(--accent);color:#06121f;border:0;padding:10px 18px;
border-radius:6px;font:inherit;font-weight:600;cursor:pointer;margin-top:12px}
button:hover{filter:brightness(1.1)}
button.ghost{background:transparent;color:var(--dim);border:1px solid var(--line);
margin-top:0;padding:5px 10px;font-size:12px}
.cmd{background:#05080c;border:1px solid var(--line);border-radius:6px;
padding:12px;margin:10px 0;word-break:break-all;white-space:pre-wrap;
font-size:12.5px;line-height:1.55}
.row{display:flex;justify-content:space-between;align-items:center;gap:12px}
.pill{font-size:11px;padding:3px 9px;border-radius:99px;font-weight:600;
letter-spacing:.05em}
.up{background:rgba(63,185,80,.15);color:var(--ok)}
.down{background:rgba(248,81,73,.15);color:var(--bad)}
table{width:100%;border-collapse:collapse}
th{text-align:left;color:var(--dim);font-size:11px;text-transform:uppercase;
letter-spacing:.08em;padding:8px 10px;border-bottom:1px solid var(--line);
font-weight:600}
td{padding:10px;border-bottom:1px solid var(--line);font-size:13px;
vertical-align:top}
tr:last-child td{border-bottom:0}
code{background:#05080c;padding:2px 6px;border-radius:4px;font-size:12px}
.err{color:var(--bad);font-size:12px}
.note{color:var(--dim);font-size:12.5px;margin-top:6px}
.banner{background:rgba(210,153,34,.1);border:1px solid rgba(210,153,34,.35);
border-radius:8px;padding:12px 14px;margin-bottom:20px;font-size:13px}
a{color:var(--accent)}
`

const indexHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Monitoring admin</title><style>` + pageCSS + `</style></head>
<body><div class="wrap">
<h1>Monitoring admin</h1>
<p class="sub">domain <code>{{.Domain}}</code> &middot; tunnel ports {{.PortRange}} &middot; panel v{{.Version}}</p>

<h2>Add a client</h2>
<div class="panel">
  <label for="name">Device name</label>
  <input id="name" placeholder="my-laptop" autocomplete="off" autofocus>
  <button onclick="add()">Generate install command</button>
  <p class="note">The keypair is generated here on the server. The private key never
  leaves this machine; only the public half goes into the command below.</p>
</div>

<div id="out"></div>

<h2>Devices</h2>
<div class="panel">
{{if .Devices}}
<table>
<tr><th>Device</th><th>Port</th><th>Status</th><th>Added</th><th></th></tr>
{{range .Devices}}
<tr>
  <td><strong>{{.Name}}</strong></td>
  <td><code>{{.Port}}</code></td>
  <td>{{$h := index $.Health .Name}}{{if $h.Up}}
      <span class="pill up">UP</span>
    {{else}}
      <span class="pill down">DOWN</span><div class="err">{{$h.Err}}</div>
    {{end}}</td>
  <td class="note">{{.Created}}</td>
  <td><button class="ghost" onclick="revoke('{{.Name}}')">revoke</button></td>
</tr>
{{end}}
</table>
{{else}}
<p class="note">No clients yet. Add one above.</p>
{{end}}
</div>

<script>
async function add(){
  const name=document.getElementById('name').value.trim();
  const out=document.getElementById('out');
  if(!name){return}
  out.innerHTML='<div class="panel">Generating&hellip;</div>';
  const r=await fetch('/api/devices?name='+encodeURIComponent(name),{method:'POST'});
  const j=await r.json();
  if(!r.ok){out.innerHTML='<div class="panel"><span class="err">'+esc(j)+'</span></div>';return}
  out.innerHTML=render(j);
}
function esc(s){const d=document.createElement('div');d.textContent=s||'';return d.innerHTML}
function render(j){
  let h='<div class="panel"><h2 style="margin-top:0">'+esc(j.device.name)+' created on port '+j.device.port+'</h2>';
  h+='<label>1 &mdash; run this on the client</label><div class="cmd" id="c1">'+esc(j.install_command)+'</div>';
  h+='<button class="ghost" onclick="cp(\'c1\',this)">copy</button>';
  h+='<label style="margin-top:18px">2 &mdash; then on THIS server, authorise the key</label>';
  j.server_steps.forEach(function(s,i){ h+='<div class="cmd" id="s'+i+'">'+esc(s)+'</div><button class="ghost" onclick="cp(\'s'+i+'\',this)">copy</button>'; });
  h+='<p class="note">The client will not report until its tunnel is up. Watch the table below, or check the proxy log.</p></div>';
  return h;
}
async function revoke(name){
  if(!confirm('Revoke '+name+'? Its key is deleted and it will stop reporting.'))return;
  const r=await fetch('/api/devices/'+encodeURIComponent(name),{method:'DELETE'});
  const j=await r.json();
  if(!r.ok){alert(j);return}
  alert('Revoked.\\n\\n'+j.server_steps.join('\\n'));
  location.reload();
}
function cp(id,btn){
  const t=document.getElementById(id).innerText;
  navigator.clipboard.writeText(t).then(function(){
    const o=btn.textContent;btn.textContent='copied';
    setTimeout(function(){btn.textContent=o},1200);
  });
}
</script>
</div></body></html>
`

var indexTmpl = template.Must(template.New("index").Parse(indexHTML))