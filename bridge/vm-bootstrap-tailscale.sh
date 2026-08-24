#!/usr/bin/env bash
set -euo pipefail

vm="david_karlsson_lovable_dev@dev-heidr-2a39.workstation.lovable.net"

ssh "$vm" 'bash -s' <<'REMOTE'
set -euo pipefail
mkdir -p "$HOME/.local/bin" "$HOME/.local/run" "$HOME/.local/state/tailscale"

if [[ ! -x "$HOME/.local/bin/tailscale" || ! -x "$HOME/.local/bin/tailscaled" ]]; then
  version=$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' | python3 -c 'import json,sys; print(json.load(sys.stdin)["Version"])')
  archive=$(mktemp)
  extract=$(mktemp -d)
  trap 'rm -f "$archive"; rm -rf "$extract"' EXIT
  curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${version}_amd64.tgz" -o "$archive"
  tar -C "$extract" -xzf "$archive"
  install -m 0755 "$extract/tailscale_${version}_amd64/tailscale" "$HOME/.local/bin/tailscale"
  install -m 0755 "$extract/tailscale_${version}_amd64/tailscaled" "$HOME/.local/bin/tailscaled"
fi

if [[ ! -S "$HOME/.local/run/tailscaled.sock" ]]; then
  nohup "$HOME/.local/bin/tailscaled" \
    --tun=userspace-networking \
    --state="$HOME/.local/state/tailscale/tailscaled.state" \
    --socket="$HOME/.local/run/tailscaled.sock" \
    >"$HOME/.local/state/tailscale/tailscaled.log" 2>&1 </dev/null &
  for _ in {1..100}; do
    [[ -S "$HOME/.local/run/tailscaled.sock" ]] && break
    sleep 0.1
  done
fi

log="$HOME/.local/state/tailscale/up.log"
: >"$log"
nohup "$HOME/.local/bin/tailscale" --socket="$HOME/.local/run/tailscaled.sock" up \
  --hostname=cockpit-work-vm >"$log" 2>&1 </dev/null &
for _ in {1..300}; do
  grep -Eq 'https://login\.tailscale\.com/' "$log" && break
  sleep 0.1
done
cat "$log"
if ! grep -Eq 'https://login\.tailscale\.com/' "$log"; then
  "$HOME/.local/bin/tailscale" --socket="$HOME/.local/run/tailscaled.sock" status || true
fi
REMOTE
