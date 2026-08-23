#!/usr/bin/env bash
set -euo pipefail

# The VM is already reachable from David's iPhone through Lovable's corporate
# Tailscale subnet router; do not install or run tailscaled on the VM.
# This deploy binds the bridge to the VM's first routed 10.x address. Corporate
# tailnet membership is not authorization: every API/WS request requires the
# bearer token at ~/.config/cockpit/bridge-token; the token is never printed.
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
token_file="$HOME/.config/cockpit/bridge-token"
bind_addr=$(hostname -I | tr ' ' '\n' | awk '/^10\./ { print; exit }')

if [[ -z "$bind_addr" ]]; then
  echo "VM has no routed 10.x address" >&2
  exit 1
fi
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
  -addr "$bind_addr:8787" \
  -runtime-dir "$bridge_runtime" \
  -static-dir "$HOME/.local/share/cockpit-mobile/web" \
  -token-file "$token_file" \
  >"$state/bridge.log" 2>&1 </dev/null &
echo $! >"$state/bridge.pid"
sleep 0.3
kill -0 "$(cat "$state/bridge.pid")"
printf 'http://%s:8787/' "$bind_addr"
REMOTE
)

printf 'Work Cockpit: %s\n' "$url"
