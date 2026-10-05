# Build and install targets for the monitoring admin panel.
#
#   make build     -> ./monitoring-admin
#   make install   -> /usr/local/bin/monitoring-admin (needs root)
#   make check     -> vet + build + a live smoke test
#
# The panel is standard-library-only Go, so this needs nothing but a toolchain.

BINARY  := monitoring-admin
VERSION := 1.0.0
PREFIX  ?= /usr/local/bin
GO      ?= go
# Pin to the local toolchain: without this Go may try to download a newer one,
# which fails on an air-gapped or slow build host.
export GOTOOLCHAIN := local

.PHONY: all build vet check test install clean

all: build

# The Go module lives in admin/, so every go command runs with that as the
# working directory. Invoking `go build ./admin` from the repo root fails with
# "go.mod file not found" because there is no module at the root.
build:
	cd admin && $(GO) build -ldflags "-X main.Version=$(VERSION)" -o ../$(BINARY) .

vet:
	cd admin && $(GO) vet .

# A real smoke test, not just a compile: start the panel on a throwaway port,
# exercise the API, then shut it down.
#
# The server is started with nohup into a log file rather than inline with `&`,
# because an inline background job keeps the recipe's shell alive and make then
# waits forever on it.
check: vet build
	@echo "==> smoke test"
	@# A previous run that was interrupted can leave the panel bound to the test
	@# port; the new instance would then fail to bind and the stale one would
	@# answer with old state, producing a baffling 409 on a fresh device name.
	@if [ -f /tmp/mon-admin-smoke.pid ]; then \
	   kill $$(cat /tmp/mon-admin-smoke.pid) 2>/dev/null || true; \
	   rm -f /tmp/mon-admin-smoke.pid; sleep 1; fi
	@rm -rf /tmp/mon-admin-smoke; mkdir -p /tmp/mon-admin-smoke
	@MON_LISTEN=127.0.0.1:18099 \
	 MON_STATE_DIR=/tmp/mon-admin-smoke \
	 MON_PROXY_PUBKEY='ssh-ed25519 AAAA-smoke-test' \
	 MON_REPO_DIR=$(CURDIR) \
	 nohup ./$(BINARY) >/tmp/mon-admin-smoke.log 2>&1 </dev/null & \
	 echo $$! >/tmp/mon-admin-smoke.pid
	@sleep 1
	@curl -fsS http://127.0.0.1:18099/healthz >/dev/null && echo "    healthz ok"
	@curl -fsS http://127.0.0.1:18099/latest-version | grep -qx $(VERSION) \
	   && echo "    /latest-version ok"
	@curl -fsS -o /dev/null http://127.0.0.1:18099/install.sh && echo "    /install.sh ok"
	@curl -fsS http://127.0.0.1:18099/ -o /dev/null && echo "    panel UI ok"
	@curl -fsS -X POST 'http://127.0.0.1:18099/api/devices?name=smoke' \
	   | grep -q '"install_command"' && echo "    device creation ok"
	# The negative cases deliberately return 4xx, so do NOT use curl -f here:
	# it would abort the recipe on the very status we are asserting.
	@curl -sS -X POST 'http://127.0.0.1:18099/api/devices?name=smoke' \
	   | grep -q 'already exists' && echo "    duplicate rejected ok"
	@# "bad name" must be percent-encoded: a literal space makes curl reject the
	@# URL before it ever reaches the panel, so the assertion would pass for the
	@# wrong reason.
	@curl -sS -X POST 'http://127.0.0.1:18099/api/devices?name=bad%20name' \
	   | grep -q 'letters, digits' && echo "    bad name rejected ok"
	@curl -sS -X POST 'http://127.0.0.1:18099/api/devices?name=smoke2' \
	   | grep -q '"port": 2202' && echo "    port allocation ok"
	@curl -sS -X DELETE 'http://127.0.0.1:18099/api/devices/smoke' \
	   | grep -q 'revoked' && echo "    revoke ok"
	@kill $$(cat /tmp/mon-admin-smoke.pid) 2>/dev/null || true
	@rm -f /tmp/mon-admin-smoke.pid
	@echo "    all checks passed"

test: check

install: build
	install -m 0755 $(BINARY) $(PREFIX)/$(BINARY)
	@echo "installed $(PREFIX)/$(BINARY)"

clean:
	rm -f $(BINARY)