#!/usr/bin/env bash
# One-shot setup for this fork on a Mac that runs omo inside herdr.
# Builds and installs the Oppi server from this checkout, wires the oppi-mirror
# extension into omo, points push at this fork's relay, installs the launchd
# service. Then pair the Oppi iOS app (TestFlight) with `oppi pair`.
#
# Re-run after `git pull` to update; existing config and pairing are kept.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${OPPI_DATA_DIR:-$HOME/.config/oppi}"
OMO_DIR="${OMO_AGENT_DIR:-$HOME/.omo/agent}"
# Push relay that serves this fork's app build (no.vastveit.Oppi).
PUSH_RELAY="https://push.agrointelserver.no"

for bin in node npm git omo herdr; do
  command -v "$bin" >/dev/null || { echo "missing required command: $bin" >&2; exit 1; }
done
[ -d "$OMO_DIR" ] || { echo "omo agent dir not found: $OMO_DIR (set OMO_AGENT_DIR)" >&2; exit 1; }

echo "==> Building server"
(cd "$REPO/server" && npm ci && npm run build)

echo "==> Installing oppi CLI (linked to this checkout)"
npm install -g "$REPO/server" --ignore-scripts
OPPI="$(command -v oppi || true)"
[ -n "$OPPI" ] || { echo "oppi is not on PATH; add \$(npm prefix -g)/bin to PATH and re-run" >&2; exit 1; }

echo "==> Installing oppi-mirror dependencies"
(cd "$REPO/pi-extensions/oppi-mirror" && { [ -f package-lock.json ] && npm ci --ignore-scripts || npm install --ignore-scripts; })

if [ ! -f "$DATA_DIR/config.json" ]; then
  echo "==> First-time server init"
  "$OPPI" init --yes --data-dir "$DATA_DIR"
fi

echo "==> Configuring server and omo"
REPO="$REPO" DATA_DIR="$DATA_DIR" OMO_DIR="$OMO_DIR" PUSH_RELAY="$PUSH_RELAY" \
OMO_BIN="$(command -v omo)" node <<'NODE'
const fs = require("fs");
const path = require("path");
const { REPO, DATA_DIR, OMO_DIR, PUSH_RELAY, OMO_BIN } = process.env;

const editJson = (file, fn) => {
  const data = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
  fn(data);
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
};

editJson(path.join(DATA_DIR, "config.json"), (c) => {
  c.runtimeEnv = { ...(c.runtimeEnv ?? {}), PI_CODING_AGENT_DIR: OMO_DIR };
  c.newSessionLauncher = { kind: "herdr-omo", command: OMO_BIN };
  c.push = { mode: "relay", relays: [PUSH_RELAY] };
});

editJson(path.join(OMO_DIR, "settings.json"), (s) => {
  const mirror = path.join(REPO, "pi-extensions/oppi-mirror");
  const packages = (s.packages ?? []).filter(
    (p) => typeof p !== "string" || !/oppi-mirror/.test(p),
  );
  s.packages = [...packages, mirror];
  s.oppiMirror = { autoStart: true, workspaceCreation: "always", ...(s.oppiMirror ?? {}) };
});
NODE
"$OPPI" config validate --config-file "$DATA_DIR/config.json"

echo "==> Installing launchd service"
"$OPPI" server install
"$OPPI" server restart >/dev/null 2>&1 || true
"$OPPI" server status

cat <<'EOF'

==> Done. Last steps:
  1. Install Oppi from the TestFlight invite on your iPhone.
  2. Run `oppi pair` here and scan the QR code with the app.
     Off your home Wi-Fi the phone needs a route to this Mac (NetBird or
     Tailscale); see `oppi pair --help` for --host.
  3. Restart or `/reload` any open omo sessions so oppi-mirror loads.
EOF
