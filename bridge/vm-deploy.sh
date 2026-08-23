#!/usr/bin/env bash
set -euo pipefail

# One-time manual VM join (never automated here): install tailscale + tailscaled in
# ~/.local/bin, then run:
#   mkdir -p ~/.local/run ~/.local/state/tailscale
#   nohup ~/.local/bin/tailscaled --tun=userspace-networking \
#     --state="$HOME/.local/state/tailscale/tailscaled.state" \
#     --socket="$HOME/.local/run/tailscaled.sock" \
#     >"$HOME/.local/state/tailscale/tailscaled.log" 2>&1 </dev/null &
#   ~/.local/bin/tailscale --socket="$HOME/.local/run/tailscaled.sock" up \
#     --hostname=dev-heidr-2a39
#   ~/.local/bin/tailscale --socket="$HOME/.local/run/tailscaled.sock" serve \
#     --bg --https=443 http://127.0.0.1:8787
# Orchestrator handover after deploy:
#   agent spawn ~/src/lovable --profile lovable-orchestrator --scope work
# Then send that new orchestrator the FULL handoff contents inline (not a proart-local
# path): "Pick up this handoff exactly where it stopped: <paste handoff contents>".
# This deploy copies only the generic bridge/app and exposes only agentd-work.sock;
# it never copies private-cockpit state or starts, stops, or modifies the VM's agentd.

vm="david_karlsson_lovable_dev@dev-heidr-2a39.workstation.lovable.net"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

npm --prefix "$root/web" install --no-package-lock
npm --prefix "$root/web" run build
(
  cd "$root/bridge"
  CGO_ENABLED=0 GOOS=linux go build -trimpath -o "$build_dir/cockpit-bridge" .
)

ssh "$vm" 'mkdir -p ~/.local/bin ~/.local/share/cockpit-mobile ~/.local/state/cockpit-mobile'
scp "$build_dir/cockpit-bridge" "$vm:.local/bin/cockpit-bridge.new"
tar -C "$root/web/dist" -czf - . | ssh "$vm" '
  set -e
  rm -rf ~/.local/share/cockpit-mobile/web.new
  mkdir -p ~/.local/share/cockpit-mobile/web.new
  tar -C ~/.local/share/cockpit-mobile/web.new -xzf -
  rm -rf ~/.local/share/cockpit-mobile/web.old
  if [ -d ~/.local/share/cockpit-mobile/web ]; then
    mv ~/.local/share/cockpit-mobile/web ~/.local/share/cockpit-mobile/web.old
  fi
  mv ~/.local/share/cockpit-mobile/web.new ~/.local/share/cockpit-mobile/web
  mv ~/.local/bin/cockpit-bridge.new ~/.local/bin/cockpit-bridge
  chmod 0755 ~/.local/bin/cockpit-bridge
'

url=$(ssh "$vm" 'bash -s' <<'REMOTE'
set -euo pipefail
runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
work_socket="$runtime/agentd-work.sock"
bridge_runtime="$HOME/.local/run/cockpit-work"
state="$HOME/.local/state/cockpit-mobile"

if [[ ! -S "$work_socket" ]]; then
  printf "agentd work socket is unavailable: %s\n" "$work_socket" >&2
  exit 1
fi
mkdir -p "$bridge_runtime" "$state"
ln -sfn "$work_socket" "$bridge_runtime/agentd-work.sock"

if [[ -s "$state/bridge.pid" ]]; then
  old_pid=$(cat "$state/bridge.pid")
  if kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid"
    for _ in {1..20}; do
      kill -0 "$old_pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
fi
nohup "$HOME/.local/bin/cockpit-bridge" \
  -addr 127.0.0.1:8787 \
  -runtime-dir "$bridge_runtime" \
  -static-dir "$HOME/.local/share/cockpit-mobile/web" \
  >"$state/bridge.log" 2>&1 </dev/null &
echo $! >"$state/bridge.pid"
sleep 0.3
kill -0 "$(cat "$state/bridge.pid")"

tailscale_bin="$HOME/.local/bin/tailscale"
tailscale_socket="$HOME/.local/run/tailscaled.sock"
if [[ ! -x "$tailscale_bin" || ! -S "$tailscale_socket" ]]; then
  echo "userspace tailscaled is not joined; follow the one-time header runbook" >&2
  exit 1
fi
dns_name=$(
  "$tailscale_bin" --socket="$tailscale_socket" status --json |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))'
)
if [[ -z "$dns_name" ]]; then
  echo "tailscale did not report a tailnet DNS name" >&2
  exit 1
fi
printf 'https://%s/' "$dns_name"
REMOTE
)

printf 'Work Cockpit: %s\n' "$url"
