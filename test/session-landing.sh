#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/cockpit-session-landing.XXXXXX)
mkdir -m 700 "$tmp/runtime"
export XDG_RUNTIME_DIR="$tmp/runtime"
pid=""
server_pid=""
cleanup() {
  for child in $server_pid; do kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; done
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
if [[ "${1:-test/session-landing.qml}" == "test/session-landing.qml" || "${1:-}" == "test/mirror-preparation.qml" || "${1:-}" == "test/open-in-nvim.qml" ]]; then
  mkdir -p "$tmp/home/.config/niri/scripts" "$tmp/home/bin"
  cp test/fake-mirror-prepare.sh "$tmp/home/.config/niri/scripts/vm-sync"
  printf '#!/usr/bin/env sh\nprintf "%%s\\n" "$*" >> "$HOME/nvim-calls"\n' > "$tmp/home/bin/nvim"
  chmod +x "$tmp/home/.config/niri/scripts/vm-sync" "$tmp/home/bin/nvim"
  touch "$tmp/home/mirror-calls" "$tmp/home/mirror-done" "$tmp/home/nvim-calls"
  export PATH="$tmp/home/bin:$PATH"
fi
if [[ "${1:-}" == "test/live-text.qml" || "${1:-}" == "test/mirror-preparation.qml" ]]; then
  sock="$tmp/agentd-personal.sock"
  [[ "${1:-}" != "test/mirror-preparation.qml" ]] || sock="$tmp/runtime/agentd-lovable.sock"
  python3 test/fake-agentd.py "$sock" >"$tmp/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do [[ -S "$sock" ]] && break; sleep 0.1; done
  [[ -S "$sock" ]]
fi
if [[ "${1:-}" == "test/diff-source.qml" ]]; then
  mkdir "$tmp/repo"
  git -C "$tmp/repo" init -q
  printf 'not the VM diff\n' > "$tmp/repo/mirror-only.txt"
  for scope in lovable work; do
    names=(local-worker)
    [[ "$scope" != work ]] || names=(remote-worker broken-worker)
    FAKE_AGENTD_CWD="$tmp/repo" python3 test/fake-agentd.py "$tmp/runtime/agentd-$scope.sock" "${names[@]}" >"$tmp/$scope.log" 2>&1 &
    server_pid="$server_pid $!"
    for _ in $(seq 1 50); do [[ -S "$tmp/runtime/agentd-$scope.sock" ]] && break; sleep 0.1; done
    [[ -S "$tmp/runtime/agentd-$scope.sock" ]]
  done
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
if [[ "${1:-}" == "test/diff-source.qml" ]]; then
  ! grep -q get_changes "$tmp/lovable.log"
  grep -q '"session": "remote-worker"' "$tmp/work.log"
  ! grep -q '"cwd":' "$tmp/work.log"
fi
