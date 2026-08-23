#!/usr/bin/env bash
set -euo pipefail

# One-time exposure: tailscale serve --bg --https=443 http://127.0.0.1:8787
# Tailscale supplies TLS and tailnet identity; this bridge remains loopback-only.
# V1 deliberately depends on proart staying awake; do not relocate it to the VM.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
web="$root/web"
bridge="$root/bridge"

if [[ ! -d "$web/node_modules" ]]; then
  npm --prefix "$web" install --no-package-lock
fi
if [[ ! -f "$web/dist/index.html" ]] || find "$web/src" "$web/public" "$web/index.html" "$web/package.json" "$web/vite.config.ts" -newer "$web/dist/index.html" -print -quit | grep -q .; then
  npm --prefix "$web" run build
fi
if [[ ! -x "$bridge/cockpit-bridge" ]] || find "$bridge" -maxdepth 1 -name '*.go' -newer "$bridge/cockpit-bridge" -print -quit | grep -q .; then
  (cd "$bridge" && go build -o cockpit-bridge .)
fi

host=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)
if [[ -n "$host" ]]; then
  printf 'Cockpit: https://%s/\n' "$host"
else
  printf 'Cockpit bridge: http://127.0.0.1:8787/ (Tailscale DNS name unavailable)\n'
fi
exec "$bridge/cockpit-bridge" -addr 127.0.0.1:8787 -static-dir "$web/dist"
