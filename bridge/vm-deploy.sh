#!/usr/bin/env bash
set -euo pipefail

# One-time VM HTTPS setup (manual; never performed by this deploy):
#   version=$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' | python3 -c 'import json,sys; print(json.load(sys.stdin)["Version"])')
#   curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${version}_amd64.tgz" | tar -xz
#   mkdir -p ~/.local/bin && install -m 0755 "tailscale_${version}_amd64"/{tailscale,tailscaled} ~/.local/bin/
# Then start userspace tailscaled and join Lovable's tailnet:
#   mkdir -p ~/.local/run ~/.local/state/tailscale
#   nohup ~/.local/bin/tailscaled --tun=userspace-networking \
#     --state="$HOME/.local/state/tailscale/tailscaled.state" \
#     --socket="$HOME/.local/run/tailscaled.sock" \
#     >"$HOME/.local/state/tailscale/tailscaled.log" 2>&1 </dev/null &
#   ~/.local/bin/tailscale --socket="$HOME/.local/run/tailscaled.sock" up \
#     --hostname=cockpit-work-vm
#   ~/.local/bin/tailscale --socket="$HOME/.local/run/tailscaled.sock" serve \
#     --bg --https=443 http://127.0.0.1:8787
# Orchestrator handover after deploy:
#   agent spawn ~/src/lovable --profile lovable-orchestrator --scope work
# Then send the new orchestrator the FULL handoff contents inline, never a proart path.
# This deploy copies only the generic bridge/app and shared bearer token, exposes only
# agentd-work.sock, and never starts, stops, or modifies the VM's agentd.

vm="david_karlsson_lovable_dev@dev-heidr-2a39.workstation.lovable.net"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_dir=$(mktemp -d)
token_file="$HOME/.config/cockpit/bridge-token"
trap 'rm -rf "$build_dir"' EXIT

if [[ ! -s "$token_file" ]] || ! grep -Eq '^[0-9a-f]{64}$' "$token_file"; then
  echo "proart bridge token is missing or invalid; start bridge/run.sh once first" >&2
  exit 1
fi

npm --prefix "$root/web" install --no-package-lock
npm --prefix "$root/web" run build
(
  cd "$root/bridge"
  CGO_ENABLED=0 GOOS=linux go build -trimpath -o "$build_dir/cockpit-bridge" .
)

ssh "$vm" 'mkdir -p ~/.config/cockpit ~/.local/bin ~/.local/share/cockpit-mobile ~/.local/state/cockpit-mobile'
scp "$build_dir/cockpit-bridge" "$vm:.local/bin/cockpit-bridge.new"
scp "$token_file" "$vm:.config/cockpit/bridge-token.new"
tar -C "$root/web/dist" -czf - . | ssh "$vm" '
  set -e
  chmod 0600 ~/.config/cockpit/bridge-token.new
  mv ~/.config/cockpit/bridge-token.new ~/.config/cockpit/bridge-token
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
tailscale_bin="$HOME/.local/bin/tailscale"
tailscale_socket="$HOME/.local/run/tailscaled.sock"

if [[ ! -S "$work_socket" ]]; then
  printf "agentd work socket is unavailable: %s\n" "$work_socket" >&2
  exit 1
fi
if [[ ! -x "$tailscale_bin" || ! -S "$tailscale_socket" ]]; then
  echo "userspace Tailscale HTTPS is not ready; follow the one-time header runbook" >&2
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
  -token-file "$token_file" \
  >"$state/bridge.log" 2>&1 </dev/null &
echo $! >"$state/bridge.pid"
sleep 0.3
kill -0 "$(cat "$state/bridge.pid")"
"$tailscale_bin" --socket="$tailscale_socket" serve --bg --https=443 http://127.0.0.1:8787 >/dev/null

dns_name=$(
  "$tailscale_bin" --socket="$tailscale_socket" status --json |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))'
)
if [[ -z "$dns_name" ]]; then
  echo "tailscale did not report the VM HTTPS hostname" >&2
  exit 1
fi
printf 'https://%s/' "$dns_name"
REMOTE
)

printf 'Work Cockpit: %s\n' "$url"
