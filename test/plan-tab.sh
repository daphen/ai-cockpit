#!/usr/bin/env bash
# The Plan tab exists only for a session with a bound plan, lights up from the editor's
# reported view, and a session switch made from it lands the next session on its plan.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d /tmp/plan-tab.XXXXXX)
qs_pid= fake_pid=
cleanup() { [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null; [ -n "$fake_pid" ] && kill "$fake_pid" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; tail -20 "$T/qs.log"; exit 1; }
cp -r qs-shell "$T/shell"; mkdir -m 700 "$T/runtime" "$T/home" "$T/bin" "$T/repo"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%s/nvim.log\n' "$T" >"$T/bin/nvim"; chmod +x "$T/bin/nvim"
SOCK=$T/runtime/agentd-personal.sock REPO=$T/repo python3 -u - <<'PY' >"$T/agentd.log" 2>&1 &
import json,os,socket,threading
repo=os.environ["REPO"]
roster=[{"id":"planned","name":"planned","status":"idle","cwd":repo,"plan":"plan-tab-fixture"},
        {"id":"planned-2","name":"planned-2","status":"idle","cwd":repo,"plan":"plan-tab-fixture-2"},
        {"id":"bare","name":"bare","status":"idle","cwd":repo}]
def serve(c):
  c.sendall((json.dumps({"type":"roster","sessions":roster})+"\n").encode()); buf=b""
  while data:=c.recv(65536):
    buf+=data
    while b"\n" in buf:
      line,buf=buf.split(b"\n",1)
      try: m=json.loads(line)
      except Exception: continue
      if m.get("type")=="get_entries": c.sendall((json.dumps({"type":"response","command":"get_entries","session":m.get("session"),"data":{"entries":[],"leafId":None}})+"\n").encode())
s=socket.socket(socket.AF_UNIX); s.bind(os.environ["SOCK"]); s.listen()
while True: threading.Thread(target=serve,args=(s.accept()[0],),daemon=True).start()
PY
fake_pid=$!
for _ in $(seq 50); do [ -S "$T/runtime/agentd-personal.sock" ] && break; sleep .1; done
INST=plan-tab-$$
mkdir -p "$T/home/.local/state/cockpit"
chin() { printf '%s' "$1" >"$T/home/.local/state/cockpit/chin-$INST.json.tmp"; mv "$T/home/.local/state/cockpit/chin-$INST.json.tmp" "$T/home/.local/state/cockpit/chin-$INST.json"; }
chin '{"path":"a.txt","cwd":"'"$T/repo"'","view":"code"}'
env -u WAYLAND_DISPLAY -u DISPLAY -u NVIM_LISTEN_ADDRESS -u COCKPIT_NVIM_SOCK -u HEIDR_NVIM_SOCK \
  PATH="$T/bin:$PATH" HOME="$T/home" XDG_RUNTIME_DIR="$T/runtime" QT_QPA_PLATFORM=offscreen \
  COCKPIT_INSTANCE=$INST COCKPIT_TITLE=$INST COCKPIT_COCKPIT_CMD=cat COCKPIT_SCOPE=personal \
  COCKPIT_AGENTD_SOCKS="$T/runtime/agentd-personal.sock" COCKPIT_ASSET_DIR="$PWD/assets" \
  QML2_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml" QML_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml" \
  qs -p "$T/shell" >"$T/qs.log" 2>&1 &
qs_pid=$!
ipc() { env XDG_RUNTIME_DIR="$T/runtime" HOME="$T/home" timeout 5 qs -p "$T/shell" ipc --any-display call cockpit "$@" 2>/dev/null | tail -1; }
field() { ipc dashboardState | python3 -c "import json,sys; v=json.load(sys.stdin)['$1']; print(','.join(v) if isinstance(v,list) else v)"; }
wait_for() { for _ in $(seq 60); do [ "$(field "$1" 2>/dev/null)" = "$2" ] && return; sleep .1; done; fail "$1 is '$(field "$1" 2>/dev/null)', wanted '$2'"; }
for _ in $(seq 100); do ipc dashboardState >/dev/null 2>&1 && break; sleep .1; done

ipc selectSession bare >/dev/null
wait_for tabs code,dashboard,vault
ipc selectSession planned >/dev/null
wait_for tabs code,dashboard,vault,plan
wait_for tab code
chin '{"path":"plans/plan-tab-fixture.md","cwd":"'"$HOME"'/personal/notes/storage","view":"plan"}'
wait_for tab plan
chin '{"path":"plans/plan-tab-fixture.md","cwd":"'"$HOME"'/personal/notes/storage","view":"vault"}'
wait_for tab vault
chin '{"path":"plans/plan-tab-fixture.md","cwd":"'"$T/repo"'","view":"plan"}'
wait_for tab plan

: >"$T/nvim.log"
ipc selectSession planned-2 >/dev/null
for _ in $(seq 40); do grep -q 'planned-2' "$T/nvim.log" 2>/dev/null && break; sleep .1; done
grep 'workspace(' "$T/nvim.log" | tail -1 | grep -q '"planned-2",".*","plan-tab-fixture-2","plan"' \
  || fail "switching from Plan did not land on the next plan: $(grep 'workspace(' "$T/nvim.log" | tail -1)"

: >"$T/nvim.log"
ipc selectSession bare >/dev/null
wait_for tabs code,dashboard,vault
wait_for tab code
for _ in $(seq 40); do grep -q '"bare"' "$T/nvim.log" 2>/dev/null && break; sleep .1; done
grep 'workspace(' "$T/nvim.log" | tail -1 | grep -q '"bare",".*","",""' \
  || fail "planless session from Plan did not fall back to Code: $(grep 'workspace(' "$T/nvim.log" | tail -1)"
echo "PASS: Plan tab follows the session's plan, lights from the editor view, and carries across switches"
