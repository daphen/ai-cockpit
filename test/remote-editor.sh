#!/usr/bin/env bash
set -Eeuo pipefail
[ "${COCKPIT_ALLOW_VISIBLE_TESTS:-}" = 1 ] || { echo "set COCKPIT_ALLOW_VISIBLE_TESTS=1" >&2; exit 2; }
cd "$(dirname "$0")/.."
command -v vmctl >/dev/null || { echo "packaged vmctl is not on PATH" >&2; exit 2; }
INSTANCE=remote-editor-integration
VM_USER=david_karlsson_lovable_dev
VM_HOST=dev-heidr-2a39.workstation.lovable.net
VM_CWD=/home/$VM_USER/src/lovable-remote-editor-integration
VM_FILE=$VM_CWD/remote-editor-test.txt
VM_PLAN=$VM_CWD/.plans/remote-editor-integration.md
LOCAL_NOTE=$HOME/personal/notes/storage/plans/remote-editor-integration.md
T=$(mktemp -d "${TMPDIR:-/tmp}/remote-editor-integration.XXXXXX")
SOCK=$T/agentd-work.sock CMD=$T/control
qs_pid= fake_pid= note_created= initial_qsid= reopen_qsid=
cleanup() {
  [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null || true
  for p in $(pgrep -f '^/nix/store/.*/bin/vmctl editor remote-editor-integration ' || true); do kill "$p" 2>/dev/null || true; done
  [ -n "$fake_pid" ] && kill "$fake_pid" 2>/dev/null || true
  rm -rf "$T" "$HOME/.local/state/cockpit/instance-$INSTANCE-shell"
  rm -f "$HOME/.local/state/cockpit/mode-$INSTANCE" "$HOME/.local/state/cockpit/selected-$INSTANCE-"*
  [ -z "$note_created" ] || rm -f "$LOCAL_NOTE"
}
on_err() { rc=$?; echo "remote editor integration failed ($rc), logs: $T" >&2; echo "initial_qsid=$initial_qsid reopen_qsid=$reopen_qsid" >&2; for p in $(pgrep -f '^/nix/store/.*/bin/vmctl editor remote-editor-integration ' || true); do echo "controller=$(tr '\0' ' ' < /proc/$p/cmdline) stderr=$(readlink /proc/$p/fd/2) backend=$(tr '\0' '\n' < /proc/$p/environ | grep '^COCKPIT_EDITOR_BACKEND=' || true)" >&2; done; ipc railState >&2 || true; ipc railTail >&2 || true; tail -n 80 "$T/qs.log" "$T/agentd.log" >&2 || true; exit "$rc"; }
trap on_err ERR
trap cleanup EXIT
if [ ! -e "$LOCAL_NOTE" ]; then printf '# remote editor integration fixture\n' >"$LOCAL_NOTE"; note_created=1; fi
SSH_BASE=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
"${SSH_BASE[@]}" "$VM_USER@$VM_HOST" "mkdir -p '$VM_CWD/.plans'; printf 'one\ntwo\nthree\nfour\n' >'$VM_FILE'; printf '# VM plan\n' >'$VM_PLAN'"
: >"$CMD"
SOCK="$SOCK" CMD="$CMD" CWD="$VM_CWD" python3 -u - <<'PY' >"$T/agentd.log" 2>&1 &
import json,os,socket,threading,time
sock,cmd,cwd=os.environ["SOCK"],os.environ["CMD"],os.environ["CWD"]; clients=[]
session={"id":"remote-editor-integration","name":"remote-editor-integration","status":"idle","cwd":cwd,"plan":"remote-editor-integration","scope":"work"}
def send(c,o):
 try:c.sendall((json.dumps(o)+"\n").encode())
 except OSError:pass
def serve(c):
 clients.append(c);print("client",len(clients),flush=True);send(c,{"type":"roster","sessions":[session]});buf=b""
 while data:=c.recv(65536):
  buf+=data
  while b"\n" in buf:
   line,buf=buf.split(b"\n",1)
   try:m=json.loads(line)
   except:continue
   if m.get("type")=="get_entries":send(c,{"type":"response","command":"get_entries","session":session["id"],"data":{"entries":[],"leafId":None}})
def drive():
 pos=0
 while True:
  time.sleep(.1)
  with open(cmd) as f:f.seek(pos); lines=f.readlines(); pos=f.tell()
  for line in lines:
   a=json.loads(line); event={"type":"tool_execution_start","session":session["id"],"toolName":"open_in_nvim","toolCallId":str(time.time()),"args":a}
   print("emit",event,flush=True)
   for c in list(clients):send(c,event)
try:os.unlink(sock)
except FileNotFoundError:pass
s=socket.socket(socket.AF_UNIX);s.bind(sock);s.listen();print("fake ready",flush=True);threading.Thread(target=drive,daemon=True).start()
while True:threading.Thread(target=serve,args=(s.accept()[0],),daemon=True).start()
PY
fake_pid=$!
for _ in {1..50}; do [ -S "$SOCK" ] && break; sleep .1; done
[ -S "$SOCK" ] || { cat "$T/agentd.log"; exit 1; }
export COCKPIT_INSTANCE=$INSTANCE COCKPIT_SCOPE=work COCKPIT_AGENTD_SOCKS=$SOCK
export COCKPIT_VM_HOST=$VM_HOST COCKPIT_VM_USER=$VM_USER
SHELL_DIR=$HOME/.local/state/cockpit/instance-$INSTANCE-shell
launch() { setsid ./run-qs.sh >>"$T/qs.log" 2>&1 & qs_pid=$!; }
qid() { qs list -a --json | python3 -c 'import json,sys; p=sys.argv[1]; print(next((x["id"] for x in json.load(sys.stdin) if x["config_path"]==p),""))' "$SHELL_DIR/shell.qml"; }
ipc() { timeout 10 qs -p "$SHELL_DIR" ipc call cockpit "$@" 2>/dev/null | tail -1; }
expr() { nvim --server "$1" --remote-expr "$2" | tr -d '\r'; }
ui() { expr "$1" 'luaeval("#vim.api.nvim_list_uis()")' 2>/dev/null || echo -1; }
open() { python3 -c 'import json,sys;print(json.dumps({"path":sys.argv[1],"line":int(sys.argv[2]),"column":int(sys.argv[3])}))' "$1" "$2" "$3" >>"$CMD"; }
wait_active() { for _ in {1..200}; do [ "$(ipc nvimSock || true)" = "$1" ] && [ "$(expr "$1" "fnamemodify(bufname(), ':p')" 2>/dev/null || true)" = "$2" ] && [ "$(ui "$1")" = 1 ] && { [ -z "${3:-}" ] || [ "$(ui "$3")" = 0 ]; } && return; sleep .1; done; return 1; }
wait_remote() { for _ in {1..200}; do EDITOR=$(ipc nvimSock || true); [[ "$EDITOR" = *"cockpit-nvim-$INSTANCE-remote.sock" ]] && [ -S "$EDITOR" ] && [ "$(ui "$EDITOR")" = 1 ] && return; sleep .1; done; return 1; }
wait_down() { for _ in {1..100}; do live=; for p in $(pgrep -x qs || true; pgrep -x quickshell || true; pgrep -x '\.quickshell-wra' || true); do tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qxF "COCKPIT_INSTANCE=$INSTANCE" && live=1; done; [ -z "$live" ] && return; sleep .1; done; return 1; }
launch; wait_remote
REMOTE=$EDITOR; initial_qsid=$(qid)
for _ in {1..100}; do [ "$(ipc railState | python3 -c 'import json,sys;print(json.load(sys.stdin).get("sel",""))' 2>/dev/null || true)" = "$INSTANCE" ] && break; sleep .1; done
[ "$(ipc railState | python3 -c 'import json,sys;print(json.load(sys.stdin).get("sel",""))')" = "$INSTANCE" ]
[ "$(expr "$REMOTE" "filereadable('$VM_PLAN')")" = 1 ]
open "$VM_FILE" 3 4; wait_active "$REMOTE" "$VM_FILE"
[ "$(expr "$REMOTE" 'line(".").":".col(".")')" = 3:4 ]
expr "$REMOTE" "setline(1, 'REMOTE-UNSAVED')" >/dev/null
PID=$(expr "$REMOTE" 'getpid()'); UIS=$(expr "$REMOTE" 'luaeval("#vim.api.nvim_list_uis()")')
open "$LOCAL_NOTE" 2 2
for _ in {1..100}; do LOCAL=$(ipc nvimSock || true); [ "$LOCAL" != "$REMOTE" ] && [ -S "$LOCAL" ] && wait_active "$LOCAL" "$LOCAL_NOTE" "$REMOTE" && break; sleep .1; done
expr "$LOCAL" "setline(1, 'LOCAL-UNSAVED')" >/dev/null
for _ in 1 2 3; do open "$VM_FILE" 3 4; wait_active "$REMOTE" "$VM_FILE" "$LOCAL"; open "$LOCAL_NOTE" 2 2; wait_active "$LOCAL" "$LOCAL_NOTE" "$REMOTE"; done
[ "$(expr "$REMOTE" "getbufline(bufnr('$VM_FILE'),1)[0]")" = REMOTE-UNSAVED ] && [ "$(expr "$REMOTE" "getbufvar(bufnr('$VM_FILE'),'&modified')")" = 1 ]
[ "$(expr "$LOCAL" "getbufline(bufnr('$LOCAL_NOTE'),1)[0]")" = LOCAL-UNSAVED ] && [ "$(expr "$LOCAL" "getbufvar(bufnr('$LOCAL_NOTE'),'&modified')")" = 1 ]
[ "$(ui "$REMOTE")" = 0 ] && [ "$(ui "$LOCAL")" = 1 ] && [ "$UIS" = 1 ]
open "$VM_FILE" 3 4; wait_active "$REMOTE" "$VM_FILE" "$LOCAL"
VMCTL=$(pgrep -f "vmctl editor $INSTANCE " | head -1); SSH=$(pgrep -P "$VMCTL" ssh | tail -1); kill "$SSH"
for _ in {1..200}; do NEW_SSH=$(pgrep -P "$VMCTL" ssh | tail -1 || true); [ -n "$NEW_SSH" ] && [ "$NEW_SSH" != "$SSH" ] && [ "$(expr "$REMOTE" 'getpid()' 2>/dev/null || true)" = "$PID" ] && break; sleep .1; done
[ "$NEW_SSH" != "$SSH" ] && [ "$(expr "$REMOTE" "getbufline(bufnr('$VM_FILE'),1)[0]")" = REMOTE-UNSAVED ]
touch "$SHELL_DIR/shell.qml"; sleep .5; wait_active "$REMOTE" "$VM_FILE"
[ "$(expr "$REMOTE" 'getpid()')" = "$PID" ] && [ "$(ui "$REMOTE")" = 1 ]
kill "$qs_pid"; wait "$qs_pid" 2>/dev/null || true; qs_pid=; wait_down
launch; for _ in {1..50}; do reopen_qsid=$(qid); [ -n "$reopen_qsid" ] && break; sleep .1; done; wait_remote
[ "$(expr "$REMOTE" 'getpid()')" = "$PID" ]
[ "$(expr "$REMOTE" "getbufline(bufnr('$VM_FILE'),1)[0]")" = REMOTE-UNSAVED ]
printf 'PASS: remote open/cursor, owner switching, disconnect, reload, reopen, persistence, and UI-client bounds\n'
