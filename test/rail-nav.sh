#!/usr/bin/env bash
# Rail cursor + autoscroll assertions against a FAKE agentd.
#
# The behaviours that kept regressing (the highlight sliding onto the wrong session, the
# feed yanking while you read, scrolling wedging) are all about what happens when the
# roster or the feed changes UNDER the cursor. That is unobservable by hand and
# untestable against the real daemon, which you cannot make add a session on cue — so
# this drives a fake one and asserts the rail's own state over its IPC.
#
#   COCKPIT_ALLOW_VISIBLE_TESTS=1 ./test/rail-nav.sh
set -uo pipefail
if [ "${COCKPIT_ALLOW_VISIBLE_TESTS:-}" != 1 ]; then
  echo "refusing to open the visible Cockpit harness; set COCKPIT_ALLOW_VISIBLE_TESTS=1 explicitly" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
B="$PWD"
# The termplugin's RUNPATH predates the repo move; resolve its deps by env,
# exactly as run-qs.sh does — without this the rail never loads and every
# assertion fails on an empty window.
export LD_LIBRARY_PATH="$B/build:$B/vendor/libghostty-vt/lib:${LD_LIBRARY_PATH:-}"
T="${TMPDIR:-/tmp}/cockpit-rail-test"
SOCK="${TMPDIR:-/tmp}/cockpit-fake-agentd.sock"
CMD="$SOCK.cmd"
LOG="$T/qs.log"
pass=0 fail=0

say()  { printf '\033[36m[rail-test]\033[0m %s\n' "$*"; }
st()   { timeout 10 qs -p "$T/qs-shell" ipc call cockpit railState 2>/dev/null | tail -1; }
key()  { timeout 10 qs -p "$T/qs-shell" ipc call cockpit railKey "$1" >/dev/null 2>&1; }
fake() { echo "$1" >> "$CMD"; sleep "${2:-2.5}"; }

# field <json> <key> — read one value without depending on jq
field() { python3 -c "import json,sys;print(json.loads(sys.argv[1]).get(sys.argv[2]))" "$1" "$2"; }

check() {   # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then say "  ✓ $1 ($2)"; pass=$((pass+1))
  else say "  ✗ $1 — got '$2', want '$3'"; fail=$((fail+1)); fi
}

# Leaving either process behind puts a fake roster on the user's desktop that looks like
# a real session — and its feed keeps growing, so it reads as a broken rail. Kill by PID
# FILE, not by pattern: `qs` re-execs as .quickshell-wrapped and a `setsid` child is not
# in this shell's job table, so pattern-matching missed it and the window survived.
cleanup() {
  for f in "$T/qs.pid" "$T/fake.pid"; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    if [ -n "${pid:-}" ]; then
      kill "$pid" 2>/dev/null
      for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$f"
  done
  # belt and braces: anything still holding this run's config dir or fake socket
  for pid in $(ps -eo pid=,args= | awk -v p="$T/qs-shell" '$0 ~ p && $0 !~ /awk/ {print $1}'); do kill -9 "$pid" 2>/dev/null; done
  for pid in $(ps -eo pid=,args= | awk -v s="$SOCK" '$0 ~ s && $0 ~ /fake-agentd/ && $0 !~ /awk/ {print $1}'); do kill -9 "$pid" 2>/dev/null; done
  rm -f "$SOCK" "$CMD"
}
trap cleanup EXIT

[ -f build/qml/Heidr/libheidr_termplugin.so ] || { echo "plugin missing — nix-shell --run 'cmake --build build -j'"; exit 1; }

cleanup
rm -rf "$T"; mkdir -p "$T/qs-shell"
# Symlink the REAL qml: a copy would silently test a snapshot. A separate config dir is
# what keeps `qs ipc` unambiguous while the user's own Cockpit keeps running.
for f in "$B"/qs-shell/*.qml; do ln -s "$f" "$T/qs-shell/$(basename "$f")"; done

say "start fake agentd"
setsid nohup python3 "$B/test/fake-agentd.py" "$SOCK" > "$T/fake.log" 2>&1 < /dev/null &
echo $! > "$T/fake.pid"
sleep 1.5
[ -S "$SOCK" ] || { echo "fake agentd did not bind $SOCK"; exit 1; }

say "launch Cockpit against it"
setsid nohup env QML2_IMPORT_PATH="$B/build/qml:$HOME/.local/share/qml" \
  QML_IMPORT_PATH="$B/build/qml:$HOME/.local/share/qml" \
  LD_LIBRARY_PATH="$B/build" QT_QPA_PLATFORM=wayland \
  COCKPIT_AGENTD_SOCKS="$SOCK" COCKPIT_COCKPIT_CMD='sh -c "while :; do sleep 60; done"' \
  qs -p "$T/qs-shell" > "$LOG" 2>&1 < /dev/null &
echo $! > "$T/qs.pid"
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

say "8. selecting a session lands the cursor in ITS feed, never on a roster row"
# The failure this pins: a pending jump-to-end was spent on a synced() triggered by ANOTHER
# session's stream tick, during the window where the switched-in transcript has not loaded.
# With no feed rows, "the end" is the last ROSTER row — so Enter dropped the cursor onto an
# unrelated session and every later signal was unforced, so nothing moved it back.
fake "slow_entries 2.5" 1          # hold the new transcript back to WIDEN that window
key g                             # roster row 0
key j; key j                      # cursor onto the third session
key enter
for _ in 1 2 3 4 5 6; do echo grow >> "$CMD"; done   # ticks land while the feed is empty
sleep 8
fake "slow_entries 0" 1
sw=$(st); scur=$(field "$sw" cur); srs=$(field "$sw" rSize); stot=$(field "$sw" navTotal)
say "  cur $scur (rSize $srs, navTotal $stot), mode $(field "$sw" mode)"
check "cursor left the roster"  "$([ "$scur" -ge "$srs" ] && echo yes || echo no)" "yes"
check "landed on the last row"  "$scur" "$((stot-1))"
check "following the live edge" "$(field "$sw" mode)" "follow"

say "10. the feed stays pinned to the live edge as messages arrive"
# "It doesn't scroll down when new messages arrive" has two possible causes and the state
# probes distinguish neither: the viewport falling behind, or the CONTENT not arriving.
# railScroll reports both — px behind the edge, and the row count.
# Select every-9001 explicitly — it is the session the fake streams into, and the earlier
# steps leave the cursor on another one. Assert on the newest row's TEXT, not the row count:
# past the 60-message cap the feed slides instead of growing, so a count is no evidence.
key g; key j; key enter; sleep 3
key G; sleep 1
b0=$(timeout 10 qs -p "$T/qs-shell" ipc call cockpit railScroll 2>/dev/null | tail -1)
r0=$(field "$(st)" row)
for _ in 1 2 3; do echo grow >> "$CMD"; sleep 1.2; done
sleep 2
b1=$(timeout 10 qs -p "$T/qs-shell" ipc call cockpit railScroll 2>/dev/null | tail -1)
r1=$(field "$(st)" row)
say "  behind $(field "$b0" behind)px -> $(field "$b1" behind)px, mode $(field "$b1" mode)"
say "  newest row: '$r0' -> '$r1'"
check "new content arrived"    "$([ "$r0" != "$r1" ] && echo yes || echo no)" "yes"
check "still at the live edge" "$([ "$(field "$b1" behind)" -le 60 ] && echo yes || echo no)" "yes"

say "9. chat cards never overlap"
# These cards reach their real height only after their prose Loader realizes (57 -> 144px).
# Inside a ListView add/displaced transition that growth never reaches the layout, so rows
# were positioned as 57px and painted over each other — visible on screen, invisible to
# every state probe. Assert on the delegates' own geometry instead.
geom=$(timeout 10 qs -p "$T/qs-shell" ipc call cockpit railGeom 2>/dev/null | tail -1)
ov=$(python3 - "$geom" <<'PY'
import json, sys
rows = json.loads(sys.argv[1] or "[]")
bad = [(a["i"], b["i"], (a["y"] + a["h"]) - b["y"])
       for a, b in zip(rows, rows[1:]) if b["y"] < a["y"] + a["h"]]
print(len(bad) if not bad else f"{len(bad)} ({bad[:3]})")
PY
)
say "  rows measured: $(python3 -c "import json,sys;print(len(json.loads(sys.argv[1] or '[]')))" "$geom")"
check "overlapping row pairs" "$ov" "0"

say "11. a live ask escapes insert mode, y answers it through the real path"
# The deadlock this pins: sending leaves the composer in insert on purpose, so an ask
# landing right after a send arrived with insert still true — the key handler's insert
# guard then ate y/n while the hidden composer had no focus. Keys went nowhere at all.
rm -f "$SOCK.answers"
key i
check "insert entered" "$(field "$(st)" ins)" "True"
fake ask
a1=$(st)
check "ask arrived"            "$(field "$a1" ask)" "True"
check "insert escaped on ask"  "$(field "$a1" ins)" "False"
key y; sleep 2
ans=$(grep -c '"type": "answer".*"confirmed": true' "$SOCK.answers" 2>/dev/null || true)
check "answer reached the daemon" "${ans:-0}" "1"
check "card cleared"              "$(field "$(st)" ask)" "False"

say "12. the stale notice: never over a streaming session, and self-heals"
# The ghost this pins: answering a live ask raced the transcript refresh — pi resumed but
# its toolResult wasn't written yet, so the recovery published 'send your answer to
# continue' over an agent that was already continuing, and nothing ever retired it.
fake stream_on 1
fake ask_in_transcript 1
fake grow                              # turn_end → transcript refresh, ask open, still streaming
check "no notice while streaming" "$(field "$(st)" stale)" "False"
fake stream_off 1
fake grow                              # refresh again: ask open, session idle → the real case
check "notice for the idle open ask" "$(field "$(st)" stale)" "True"
fake answer_in_transcript 1
fake grow                              # refresh: transcript now shows the answer
check "notice self-healed" "$(field "$(st)" stale)" "False"

say "13. interrupt vs kill: Esc/x abort the TURN, roster-x kills the SESSION"
# x used to send the daemon's stop from anywhere — session killed, roster row gone, on
# one unconfirmed keypress. Now: Esc in the composer (and x outside the roster) sends
# pi's turn-abort and the session SURVIVES; x on a roster row keeps the kill semantics.
rm -f "$SOCK.answers"
fake stream_on
key G                                # cursor in the feed
key i                                # composer focused, insert on
key esc; sleep 2                     # Esc while streaming = interrupt
ab=$(grep -c '"type": "abort"' "$SOCK.answers" 2>/dev/null)
check "Esc sent the abort"          "${ab:-0}" "1"
check "session survived interrupt"  "$(field "$(st)" rSize)" "3"
key esc                              # now idle: Esc = plain leave-insert
check "second Esc left insert"      "$(field "$(st)" ins)" "False"
key G; key x; sleep 1                # x outside the roster must do NOTHING now
check "feed-x is inert (roster intact)" "$(field "$(st)" rSize)" "3"
key g; key j; key j                  # roster cursor onto zulu-9999
key x; sleep 2                       # roster-x = kill THAT session
kl=$(grep -c '"type": "stop", "session": "zulu-9999"' "$SOCK.answers" 2>/dev/null)
check "roster-x killed the row's session" "${kl:-0}" "1"
check "roster shrank" "$(field "$(st)" rSize)" "2"

say "14. enter steers a live turn; ctrl+enter queues; abort flushes the queue"
# The Claude Code model: steering redirects the running turn (default), a queued message
# waits for agent_end — which an ABORT also emits, so interrupting picks the queued
# item up immediately instead of leaving it in limbo.
rm -f "$SOCK.answers"
fake insert 1                          # restore a 3-row roster (13 killed zulu-9999)
fake stream_on
ipc_send() { timeout 10 qs -p "$T/qs-shell" ipc call cockpit "$1" "$2" >/dev/null 2>&1; }
ipc_send railSend "redirect please"; sleep 1.5
steered=$(grep -c '"type": "steer", "session": "every-9001", "message": "redirect please"' "$SOCK.answers" 2>/dev/null)
check "enter while busy STEERED" "${steered:-0}" "1"
ipc_send railQueue "do this next"; sleep 1
check "message queued" "$(field "$(st)" q)" "1"
qp=$(grep -c '"type": "prompt".*do this next' "$SOCK.answers" 2>/dev/null)
check "not sent yet" "${qp:-0}" "0"
key G                                  # cursor into the feed
key esc; sleep 3                       # esc = interrupt, everywhere
qp2=$(grep -c '"message": "do this next"' "$SOCK.answers" 2>/dev/null)
check "abort flushed the queued item" "${qp2:-0}" "1"
check "queue empty" "$(field "$(st)" q)" "0"

say "15. a steered message stays visible until the transcript catches up"
# Steered messages sit in pi's queue until a tool boundary: absent from get_entries for a
# while. The optimistic row used to be wiped by the next rebuild — sends silently
# vanished, then all appeared at once when pi consumed the queue.
fake stream_on
ipc_send railSend "steer me visible"; sleep 1
fake grow                              # turn_end → full transcript rebuild, steer NOT in it
vis=$(timeout 10 qs -p "$T/qs-shell" ipc call cockpit railGeom >/dev/null 2>&1; st)
key G
check "echo survived the rebuild" "$(field "$(st)" row | grep -c "steer me visible")" "1"
say "16. turn outcomes render: retry, retry-exhausted, compaction, tool failure"
fake retry 1
live=$(timeout 10 qs -p "$T/qs-shell" ipc call cockpit railTail 2>/dev/null | tail -1)
check "retry status shows live" "$(case "$live" in *"retrying (1/3)"*) echo 1;; *) echo 0;; esac)" "1"
fake retry_fail 1
fake compacting 1
fake toolfail 1
live=$(timeout 10 qs -p "$T/qs-shell" ipc call cockpit railTail 2>/dev/null | tail -1)
check "failed tool row shows live" "$(case "$live" in *"bash false"*) echo 1;; *) echo 0;; esac)" "1"
# After a transcript rebuild the lifecycle applies: the retry status is REPLACED by
# its outcome, and the outcome rows persist via the transient overlay.
sleep 6
tail=$(timeout 10 qs -p "$T/qs-shell" ipc call cockpit railTail 2>/dev/null | tail -1)
found=0
for want in "context compacted" "retries exhausted"; do
  case "$tail" in *"$want"*) found=$((found+1));; *) say "  MISSING: $want";; esac
done
check "outcomes persist across rebuilds" "$found" "2"
check "retry status was replaced by its outcome" "$(case "$tail" in *"retrying (1/3)"*) echo 1;; *) echo 0;; esac)" "0"

say "17. a background session's ask is globally visible"
key g; key enter; sleep 2                 # select alpha-1000 (NOT the ask target)
fake ask 1                                # live ask lands on every-9001
check "ask counted while another session selected" "$(field "$(st)" asksTotal)" "1"
check "selected session's chin NOT hijacked" "$(field "$(st)" ask)" "False"

say "18. command cards wait for one explicit human Run and keep the result inline"
key g; key j; key j; key enter; sleep 1
check "command target selected" "$(field "$(st)" sel)" "every-9001"
rm -f "$SOCK.answers"
fake user_bash 1
check "command card arrived" "$(field "$(st)" ask)" "True"
preauth=$(grep -c 'fake-user-bash-1\|confirmed' "$SOCK.answers" 2>/dev/null || true)
check "nothing authorized before Run" "${preauth:-0}" "0"
key y; sleep 2
runs=$(grep -c '"confirmed": true' "$SOCK.answers" 2>/dev/null || true)
check "Run authorized exactly once" "${runs:-0}" "1"
check "command card cleared" "$(field "$(st)" ask)" "False"
key G; sleep 1
output=$(timeout 10 qs -p "$T/qs-shell" ipc call cockpit railTail 2>/dev/null || true)
check "durable approval rebuilt in place" "$(case "$output" in *"ask:❯ ! printf immutable-command"*) echo 1;; *) echo 0;; esac)" "1"
check "user-bash skipped the temporary echo" "$(python3 -c 'import sys; print(sys.argv[1].count("printf immutable-command"))' "$output")" "1"
check "command output stayed inline" "$(case "$output" in *"Command completed with exit status 0"*) echo 1;; *) echo 0;; esac)" "1"
rm -f "$SOCK.answers"
fake user_bash 1
key n; sleep 1
declines=$(grep -c '"confirmed": false' "$SOCK.answers" 2>/dev/null || true)
check "Decline answered once without Run" "${declines:-0}" "1"

say "6. no QML errors during the run"
errs=$(grep -icE 'WARN|Error' "$LOG")
check "error lines" "$errs" "0"

say "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
