#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/cockpit-session-landing.XXXXXX)
mkdir -m 700 "$tmp/runtime"
export XDG_RUNTIME_DIR="$tmp/runtime"
pid=""
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  if [[ -n "$pid" ]]; then
    local link="$XDG_RUNTIME_DIR/quickshell/by-pid/$pid"
    local entry
    entry=$(readlink -f "$link" || true)
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$link"
    [[ "$entry" != "$XDG_RUNTIME_DIR/quickshell/by-id/"* ]] || rm -rf "$entry"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
cp qs-shell/*.qml "$tmp/"
cp "${1:-test/session-landing.qml}" "$tmp/shell.qml"
mkdir -p "$tmp/home"
if [[ "${1:-}" == "test/mirror-preparation.qml" || "${1:-}" == "test/open-in-nvim.qml" ]]; then
  mkdir -p "$tmp/home/.config/niri/scripts" "$tmp/home/bin"
  cp test/fake-mirror-prepare.sh "$tmp/home/.config/niri/scripts/vm-sync"
  printf '#!/usr/bin/env sh\nprintf "%%s\\n" "$*" >> "$HOME/nvim-calls"\n' > "$tmp/home/bin/nvim"
  chmod +x "$tmp/home/.config/niri/scripts/vm-sync" "$tmp/home/bin/nvim"
  touch "$tmp/home/mirror-calls" "$tmp/home/mirror-done" "$tmp/home/nvim-calls"
  export PATH="$tmp/home/bin:$PATH"
fi
if [[ "${1:-}" == "test/live-text.qml" ]]; then
  python3 test/fake-agentd.py "$tmp/agentd-personal.sock" >"$tmp/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do [[ -S "$tmp/agentd-personal.sock" ]] && break; sleep 0.1; done
  [[ -S "$tmp/agentd-personal.sock" ]]
fi
env -u WAYLAND_DISPLAY HOME="$tmp/home" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$HOME/.local/share/qml" \
  qs -p "$tmp" >"$tmp/output" 2>&1 &
pid=$!
for _ in $(seq 1 50); do
  grep -qE 'PASS:|ERROR|Error:' "$tmp/output" && break
  sleep 0.1
done
if grep -E 'ERROR|Error:' "$tmp/output"; then exit 1; fi
grep 'PASS:' "$tmp/output"
