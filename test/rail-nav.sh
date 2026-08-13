#!/usr/bin/env bash
# Rail cursor + autoscroll assertions against a FAKE agentd.
#
# The behaviours that kept regressing (the highlight sliding onto the wrong session, the
# feed yanking while you read, scrolling wedging) are all about what happens when the
# roster or the feed changes UNDER the cursor. That is unobservable by hand and
# untestable against the real daemon, which you cannot make add a session on cue — so
# this drives a fake one and asserts the rail's own state over its IPC.
#
#   ./test/rail-nav.sh          run the suite (spawns its own heidr, tears it down)
set -uo pipefail
cd "$(dirname "$0")/.."
B="$PWD"
T="${TMPDIR:-/tmp}/heidr-rail-test"
SOCK="${TMPDIR:-/tmp}/heidr-fake-agentd.sock"
CMD="$SOCK.cmd"
LOG="$T/qs.log"
pass=0 fail=0

say()  { printf '\033[36m[rail-test]\033[0m %s\n' "$*"; }
st()   { timeout 10 qs -p "$T/qs-shell" ipc call heidr railState 2>/dev/null | tail -1; }
key()  { timeout 10 qs -p "$T/qs-shell" ipc call heidr railKey "$1" >/dev/null 2>&1; }
fake() { echo "$1" >> "$CMD"; sleep "${2:-2.5}"; }

# field <json> <key> — read one value without depending on jq
field() { python3 -c "import json,sys;print(json.loads(sys.argv[1]).get(sys.argv[2]))" "$1" "$2"; }

check() {   # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then say "  ✓ $1 ($2)"; pass=$((pass+1))
  else say "  ✗ $1 — got '$2', want '$3'"; fail=$((fail+1)); fi
}

cleanup() {
  for pid in $(ps -eo pid=,args= | awk -v p="$T/qs-shell" '$0 ~ p && $0 !~ /awk/ {print $1}'); do kill "$pid" 2>/dev/null; done
  for pid in $(ps -eo pid=,args= | awk '$0 ~ /fake-agentd\.py/ && $0 !~ /awk/ {print $1}'); do kill "$pid" 2>/dev/null; done
  rm -f "$SOCK" "$CMD"
}
trap cleanup EXIT

[ -f build/qml/Heidr/libheidr_termplugin.so ] || { echo "plugin missing — nix-shell --run 'cmake --build build -j'"; exit 1; }

cleanup
rm -rf "$T"; mkdir -p "$T/qs-shell"
# Symlink the REAL qml: a copy would silently test a snapshot. A separate config dir is
# what keeps `qs ipc` unambiguous while the user's own heidr keeps running.
for f in "$B"/qs-shell/*.qml; do ln -s "$f" "$T/qs-shell/$(basename "$f")"; done

say "start fake agentd"
setsid nohup python3 "$B/test/fake-agentd.py" "$SOCK" > "$T/fake.log" 2>&1 < /dev/null &
sleep 1.5
[ -S "$SOCK" ] || { echo "fake agentd did not bind $SOCK"; exit 1; }

say "launch heidr against it"
setsid nohup env QML2_IMPORT_PATH="$B/build/qml:$HOME/.local/share/qml" \
  QML_IMPORT_PATH="$B/build/qml:$HOME/.local/share/qml" \
  LD_LIBRARY_PATH="$B/build" QT_QPA_PLATFORM=wayland \
  HEIDR_AGENTD_SOCKS="$SOCK" HEIDR_COCKPIT_CMD='sh -c "while :; do sleep 60; done"' \
  qs -p "$T/qs-shell" > "$LOG" 2>&1 < /dev/null &
for _ in $(seq 1 30); do sleep 1; [ -n "$(st)" ] && break; done
[ -n "$(st)" ] || { echo "rail never answered ipc; log:"; tail -20 "$LOG"; exit 1; }

say "1. roster cursor is anchored to a SESSION, not a row number"
key g; key j
before=$(st)
check "anchored on every-9001" "$(field "$before" key)" "r:every-9001"
check "at row 1"               "$(field "$before" cur)" "1"
fake insert                      # aaa-inserted sorts first, so every-9001 shifts down
after=$(st)
check "still every-9001 after a session appeared above it" "$(field "$after" key)" "r:every-9001"
check "row followed the session"                           "$(field "$after" cur)" "2"
fake remove
back=$(st)
check "row followed back"      "$(field "$back" cur)" "1"

say "2. selecting a streaming session lands at the newest message, following"
key enter; sleep 3; fake stream_on
key G
sel=$(st)
check "mode" "$(field "$sel" mode)" "follow"
n0=$(field "$sel" navTotal); c0=$(field "$sel" cur)
check "cursor on the last row" "$c0" "$((n0-1))"

say "3. while following, the cursor tracks new rows"
fake grow 6
g=$(st); n1=$(field "$g" navTotal)
[ "$n1" -gt "$n0" ] && say "  (feed grew $n0 -> $n1)" || say "  ! feed did not grow — check the fake"
check "cursor still on the last row" "$(field "$g" cur)" "$((n1-1))"

say "4. reading mid-feed is preserved across growth"
key k; key k
r=$(st); cr=$(field "$r" cur)
check "mode leaves follow" "$(field "$r" mode)" "free"
fake grow 6
r2=$(st)
check "cursor did not move" "$(field "$r2" cur)" "$cr"
check "still free"          "$(field "$r2" mode)" "free"

say "5. a cursor in the ROSTER is never yanked into the feed by growth"
key g
ro=$(st)
check "on a roster row" "$(field "$ro" cur)" "0"
fake grow 6
ro2=$(st)
check "still on the roster row" "$(field "$ro2" cur)" "0"

say "7. reading survives the 60-message cap SLIDING (long session)"
# Past the cap the feed stops growing and instead slides: a row's index shifts by one per
# new message, so anything keyed on the index lands on a neighbouring turn.
key G; sleep 1
for _ in $(seq 1 34); do echo grow >> "$CMD"; done
sleep 8
key G; key k; key k; key k      # read three rows up from the newest
# Assert on the row's CONTENT: comparing the anchor key to itself would pass even when the
# cursor is sitting on a different turn, which is exactly how this test first fooled me.
a=$(st); arow=$(field "$a" row); acur=$(field "$a" cur); atot=$(field "$a" navTotal)
say "  reading row $acur (navTotal $atot): '$arow'"
fake grow 7
fake grow 7
b=$(st); brow=$(field "$b" row); bcur=$(field "$b" cur); btot=$(field "$b" navTotal)
say "  now row $bcur (navTotal $btot): '$brow'"
check "same message still under the cursor" "$brow" "$arow"
if [ "$btot" = "$atot" ] && [ "$bcur" -lt "$acur" ]; then
  say "  ✓ window slid and the row index followed it ($acur -> $bcur)"; pass=$((pass+1))
elif [ "$btot" -gt "$atot" ]; then
  say "  – cap not reached (navTotal still growing $atot -> $btot); identity check above still applies"
else
  say "  ✗ expected the row to slide up, got $acur -> $bcur"; fail=$((fail+1))
fi

say "6. no QML errors during the run"
errs=$(grep -icE 'WARN|Error' "$LOG")
check "error lines" "$errs" "0"

say "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
