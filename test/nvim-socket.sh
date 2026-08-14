#!/usr/bin/env bash
# nvim RPC socket assertions — the rail's session-follow depends on ONE thing: that the
# path heidr publishes as `nvimSocket` has a live nvim behind it. That was broken for a day
# in a way no manual check catches, because the failure is silent: `nvim --remote` against a
# deleted path exits 0-ish through execDetached and the editor simply never moves.
#
# Runs against build-vendored so it never swaps the .so under the user's live cockpit
# (overwriting a mapped plugin put a running instance into a crash-restart loop).
#
#   ./test/nvim-socket.sh
set -uo pipefail
cd "$(dirname "$0")/.."
B="$PWD"
BUILD="${HEIDR_TEST_BUILD:-build-vendored}"
T="${TMPDIR:-/tmp}/heidr-nvimsock-test"
SOCK="${TMPDIR:-/tmp}/heidr-nvimsock-fake.sock"
RT="${XDG_RUNTIME_DIR:-/tmp}"
STABLE="$RT/heidr-nvim.sock"
pass=0 fail=0

say()   { printf '\033[36m[nvim-sock]\033[0m %s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then say "  ✓ $1 ($2)"; pass=$((pass+1))
          else say "  ✗ $1 — got '$2', want '$3'"; fail=$((fail+1)); fi; }
# ask the nvim behind a socket who it is; empty when nothing is listening there
who()   { timeout 5 nvim --server "$1" --remote-expr 'getpid()' 2>/dev/null | tr -d '\r\n'; }

cleanup() {
  for f in "$T"/qs*.pid "$T/fake.pid"; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "${pid:-}" ] && { kill "$pid" 2>/dev/null
      for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; }
    rm -f "$f"
  done
  for pid in $(ps -eo pid=,args= | awk -v p="$T/qs-shell" '$0 ~ p && $0 !~ /awk/ {print $1}'); do kill -9 "$pid" 2>/dev/null; done
  for pid in $(ps -eo pid=,args= | awk -v s="$SOCK" '$0 ~ s && $0 ~ /fake-agentd/ && $0 !~ /awk/ {print $1}'); do kill -9 "$pid" 2>/dev/null; done
  rm -f "$SOCK" "$SOCK.cmd"
}
trap cleanup EXIT

[ -f "$BUILD/qml/Heidr/libheidr_termplugin.so" ] || { echo "plugin missing in $BUILD — nix-shell --run 'cmake --build $BUILD -j'"; exit 1; }
# A live cockpit of the user's own would make "who owns the stable path" ambiguous.
if [ -n "$(who "$STABLE")" ]; then
  echo "something already answers on $STABLE — close that cockpit (or point XDG_RUNTIME_DIR elsewhere) and rerun"; exit 1
fi

cleanup
rm -rf "$T"; mkdir -p "$T/qs-shell"
for f in "$B"/qs-shell/*.qml; do ln -s "$f" "$T/qs-shell/$(basename "$f")"; done

setsid nohup python3 "$B/test/fake-agentd.py" "$SOCK" > "$T/fake.log" 2>&1 < /dev/null &
echo $! > "$T/fake.pid"
sleep 1.5
[ -S "$SOCK" ] || { echo "fake agentd did not bind $SOCK"; exit 1; }

launch() {   # launch <tag> — a cockpit with the REAL default command, i.e. a real nvim
  setsid nohup env QML2_IMPORT_PATH="$B/$BUILD/qml:$HOME/.local/share/qml" \
    QML_IMPORT_PATH="$B/$BUILD/qml:$HOME/.local/share/qml" \
    LD_LIBRARY_PATH="$B/$BUILD" QT_QPA_PLATFORM=wayland \
    HEIDR_AGENTD_SOCKS="$SOCK" \
    qs -p "$T/qs-shell" > "$T/qs-$1.log" 2>&1 < /dev/null &
  echo $! > "$T/qs-$1.pid"
}

say "1. a cockpit publishes a socket a live nvim answers on"
launch a
for _ in $(seq 1 30); do sleep 1; [ -n "$(who "$STABLE")" ] && break; done
first=$(who "$STABLE")
check "stable path has a live nvim" "$([ -n "$first" ] && echo yes || echo no)" "yes"

say "2. a SECOND cockpit does not clobber the first one's nvim"
# The regression: the launch command used to `rm -f` the path before binding, so this step
# left the first nvim running on an inode nobody could reach again.
launch b
sleep 12
still=$(who "$STABLE")
check "first nvim still reachable"  "$still" "$first"
# and the second must have taken a private path of its own, not gone socket-less
priv=""
for s in "$RT"/heidr-nvim-*.sock; do
  [ -e "$s" ] || continue
  p=$(who "$s"); [ -n "$p" ] && [ "$p" != "$first" ] && priv="$s"
done
check "second cockpit got its own live socket" "$([ -n "$priv" ] && echo yes || echo no)" "yes"

say "3. a stale socket FILE is not a blocker"
# nvim unlinks a dead socket itself, which is why heidr no longer does it.
cleanup
python3 - "$STABLE" <<'PY'
import socket, sys, os
p = sys.argv[1]
os.path.exists(p) and os.unlink(p)
s = socket.socket(socket.AF_UNIX); s.bind(p); s.close()
PY
setsid nohup python3 "$B/test/fake-agentd.py" "$SOCK" > "$T/fake.log" 2>&1 < /dev/null &
echo $! > "$T/fake.pid"; sleep 1.5
launch c
for _ in $(seq 1 30); do sleep 1; [ -n "$(who "$STABLE")" ] && break; done
check "bound over the stale file" "$([ -n "$(who "$STABLE")" ] && echo yes || echo no)" "yes"

say "4. nvim itself refuses to steal a live address (the assumption the fix rests on)"
# heidr no longer guards the bind at all: it relies on nvim unlinking a dead socket (3) and
# refusing a live one (here). If an nvim upgrade ever changed THAT, the cockpit would go
# back to silently hijacking another instance's editor — so assert it, don't assume it.
cleanup
P="$RT/heidr-nvim-assume.sock"; rm -f "$P"
NVIM_LISTEN_ADDRESS="$P" setsid nohup nvim --headless > "$T/owner.log" 2>&1 < /dev/null &
echo $! > "$T/qs-owner.pid"
for _ in $(seq 1 15); do sleep 0.5; [ -n "$(who "$P")" ] && break; done
owner=$(who "$P")
timeout 10 nvim --listen "$P" --headless -c 'qa!' >/dev/null 2>&1; intruder=$?
check "the intruder was rejected"  "$([ "$intruder" -ne 0 ] && echo yes || echo no)" "yes"
check "the owner still holds it"   "$(who "$P")" "$owner"
timeout 5 nvim --server "$P" --remote-send '<C-\><C-N>:qa!<CR>' >/dev/null 2>&1
rm -f "$P"

say "5. the launch command never unlinks the socket (source guard)"
# A source check, not behavioural: the deleted-live-socket failure needs two cockpits
# starting inside the same second to reproduce, which is not something a test can time
# reliably. The mistake itself is one grep away, so guard it there.
check "no rm of NVIM_LISTEN_ADDRESS" \
  "$(grep -v '^[[:space:]]*//' TermView.cpp | grep -c 'rm .*NVIM_LISTEN_ADDRESS')" "0"

say "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
