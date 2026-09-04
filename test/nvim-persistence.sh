#!/usr/bin/env bash
set -uo pipefail
if [ "${COCKPIT_ALLOW_VISIBLE_TESTS:-}" != 1 ]; then
  echo "refusing to open the visible Cockpit harness; set COCKPIT_ALLOW_VISIBLE_TESTS=1 explicitly" >&2
  exit 2
fi
: "${NVIM_013_BIN:?set NVIM_013_BIN to the exact nvim-013 executable}"
cd "$(dirname "$0")/.." || exit
B=$PWD
T="${TMPDIR:-/tmp}/cockpit-nvim-persistence-$$"
SOCK="${TMPDIR:-/tmp}/cockpit-nvim-persistence-agentd-$$.sock"
INSTANCE="nvim-013-spike-$$"
QS_BIN=${QS_BIN:-$(command -v qs)}
[ -n "$QS_BIN" ] || { echo "qs is not on PATH" >&2; exit 1; }
pass=0 fail=0 qs_pid='' fake_pid=''

say() { printf '\033[36m[nvim-persist]\033[0m %s\n' "$*"; }
check() {
  if [ "$2" = "$3" ]; then say "  ✓ $1 ($2)"; pass=$((pass + 1))
  else say "  ✗ $1 — got '$2', want '$3'"; fail=$((fail + 1)); fi
}
cleanup() {
  [ -n "${qs_pid:-}" ] && kill "$qs_pid" 2>/dev/null
  [ -n "${fake_pid:-}" ] && kill "$fake_pid" 2>/dev/null
  for pid in ${qs_pid:-} ${fake_pid:-}; do
    [ -n "$pid" ] || continue
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep .1; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  done
  rm -f "$SOCK" "$SOCK.cmd"
  rm -f "$HOME/.local/state/cockpit/chin-$INSTANCE.json" \
        "$HOME/.local/state/cockpit/mode-$INSTANCE" \
        "$HOME/.local/state/cockpit/selected-$INSTANCE-"*
}
trap cleanup EXIT

rm -rf "$T"
mkdir -p "$T/qs-shell" "$T/bin" "$T/state" "$T/cache"
cp -a qs-shell/. "$T/qs-shell/"
ln -s "$NVIM_013_BIN" "$T/bin/nvim-013"

python3 test/fake-agentd.py "$SOCK" >"$T/fake.log" 2>&1 &
fake_pid=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep .1; done
[ -S "$SOCK" ] || { echo "fake agentd did not start" >&2; exit 1; }

export QML2_IMPORT_PATH="$B/build/qml:$HOME/.local/share/qml"
export QML_IMPORT_PATH="$QML2_IMPORT_PATH"
export LD_LIBRARY_PATH="$B/build:$B/vendor/libghostty-vt/lib:${LD_LIBRARY_PATH:-}"
export PATH="$T/bin:$PATH"
export XDG_STATE_HOME="$T/state"
export XDG_CACHE_HOME="$T/cache"
export COCKPIT_INSTANCE="$INSTANCE"
export COCKPIT_AGENTD_SOCKS="$SOCK"
export NVIM_PROFILE=full
setsid "$QS_BIN" -p "$T/qs-shell" >"$T/qs.log" 2>&1 &
qs_pid=$!

ipc() { timeout 10 "$QS_BIN" -p "$T/qs-shell" ipc call cockpit "$@" 2>/dev/null | tail -1; }
editor_socket=
for _ in $(seq 1 100); do
  editor_socket=$(ipc nvimSock || true)
  [ -S "$editor_socket" ] && break
  sleep .1
done
[ -S "$editor_socket" ] || { tail -60 "$T/qs.log" >&2; exit 1; }
remote() { timeout 10 "$NVIM_013_BIN" --server "$editor_socket" --remote-expr "$1" | tr -d '\r'; }

for _ in $(seq 1 100); do
  [ "$(remote 'luaeval("#vim.api.nvim_list_uis()")' 2>/dev/null || echo 0)" = 1 ] && break
  sleep .1
done
version=$(remote 'luaeval("vim.version().minor")')
pid_before=$(remote 'getpid()')
embedded_mode=$(remote 'luaeval("vim.env.COCKPIT_COCKPIT or _A", "")')
listen_env=$(remote 'luaeval("vim.env.NVIM_LISTEN_ADDRESS or _A", "")')
test_file=/home/daphen/personal/newtab/src/popup/main.tsx
remote "execute(\"cd /home/daphen/personal/newtab | edit $test_file\")" >/dev/null
test_buffer=$(remote "bufnr('$test_file')")
clients_before=
for _ in $(seq 1 50); do
  clients_before=$(remote "luaeval(\"table.concat(vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients({bufnr=_A})), string.char(44))\", $test_buffer)")
  [[ "$clients_before" == *tailwindcss* && "$clients_before" == *ts_ls* ]] && break
  sleep .1
done
remote "execute(\"buffer $test_buffer | call setline(1, 'spike-one')\")" >/dev/null
remote "execute(\"buffer $test_buffer | call setline(1, 'spike-two') | only | vsplit\")" >/dev/null
windows_before=$(remote "luaeval(\"#vim.fn.win_findbuf(_A)\", $test_buffer)")
for _ in $(seq 1 20); do
  [ "$windows_before" = 2 ] && break
  remote "execute(\"buffer $test_buffer | only | vsplit\")" >/dev/null
  windows_before=$(remote "luaeval(\"#vim.fn.win_findbuf(_A)\", $test_buffer)")
  sleep .1
done
[ "$windows_before" = 2 ] || { echo "could not establish two-window test layout" >&2; exit 1; }
line_before=$(remote "getbufline($test_buffer, 1)[0]")
modified_before=$(remote "getbufvar($test_buffer, '&modified')")

printf '\n' >> "$T/qs-shell/shell.qml"
socket_after=
for _ in $(seq 1 150); do
  socket_after=$(ipc nvimSock || true)
  [ "$socket_after" = "$editor_socket" ] || { sleep .1; continue; }
  uis=$(remote 'luaeval("#vim.api.nvim_list_uis()")' 2>/dev/null || echo 0)
  [ "$uis" = 1 ] && break
  sleep .1
done
pid_after=$(remote 'getpid()')
line_after=$(remote "getbufline($test_buffer, 1)[0]")
modified_after=$(remote "getbufvar($test_buffer, '&modified')")
windows_after=$(remote "luaeval(\"#vim.fn.win_findbuf(_A)\", $test_buffer)")
clients_after=$(remote "luaeval(\"table.concat(vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients({bufnr=_A})), string.char(44))\", $test_buffer)")
remote "luaeval(\"vim.api.nvim_set_current_buf(_A)\", $test_buffer)" >/dev/null
remote 'execute("undo")' >/dev/null
line_after_undo=$(remote "getbufline($test_buffer, 1)[0]")
remote "setbufvar($test_buffer, '&modified', 0)" >/dev/null
follow_file="$T/follow-target.txt"
printf 'one\ntwo\nthree\nexplicit hunk\nfive\nsnippet target\nseven\n' >"$follow_file"
remote "v:lua.require('cockpit').follow_remote('$T', '$follow_file', v:true, 4)" >/dev/null
follow_buffer=$(remote "bufnr('$follow_file')")
follow_path=$(remote "fnamemodify(bufname($follow_buffer), ':p')")
follow_hunk_line=$(remote "getcurpos(win_findbuf($follow_buffer)[0])[1]")
needle_b64=$(printf 'snippet target' | base64 -w0)
remote "v:lua.require('cockpit').follow_remote('$T', '$follow_file', v:true, v:null, '$needle_b64')" >/dev/null
follow_snippet_line=$(remote "getcurpos(win_findbuf($follow_buffer)[0])[1]")

say "reload keeps one editor"
check "Neovim 0.13" "$version" "13"
check "embedded Cockpit mode" "$embedded_mode" "1"
check "server socket environment" "$listen_env" "$editor_socket"
check "stable socket" "$socket_after" "$editor_socket"
check "same server PID" "$pid_after" "$pid_before"
check "unsaved text" "$line_after" "$line_before"
check "modified flag" "$modified_after" "$modified_before"
check "two-window layout" "$windows_after" "2"
check "undo history" "$line_after_undo" "spike-one"
check "LSP clients" "$clients_after" "$clients_before"
check "LSP attached" "$([ -n "$clients_after" ] && echo yes || echo no)" "yes"
check "live-follow file" "$follow_path" "$follow_file"
check "live-follow hunk" "$follow_hunk_line" "4"
check "live-follow snippet" "$follow_snippet_line" "6"

kill "$qs_pid" 2>/dev/null
for _ in $(seq 1 100); do kill -0 "$qs_pid" 2>/dev/null || break; sleep .1; done
kill -0 "$qs_pid" 2>/dev/null && kill -9 "$qs_pid" 2>/dev/null
wait "$qs_pid" 2>/dev/null || true
qs_pid=
for _ in $(seq 1 50); do [ ! -S "$editor_socket" ] && break; sleep .1; done
left=$(ps -eo pgid= | awk -v pg="$pid_before" '$1 == pg {n++} END {print n+0}')

say "owner teardown"
check "socket removed" "$([ ! -S "$editor_socket" ] && echo yes || echo no)" "yes"
check "owned processes removed" "$left" "0"
say "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
