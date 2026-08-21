#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

RT="${XDG_RUNTIME_DIR:-/tmp}"
pass=0
fail=0

say() { printf '\033[36m[nvim-sock]\033[0m %s\n' "$*"; }
check() {
  if [ "$2" = "$3" ]; then
    say "  ✓ $1 ($2)"
    pass=$((pass + 1))
  else
    say "  ✗ $1 — got '$2', want '$3'"
    fail=$((fail + 1))
  fi
}
who() { timeout 5 nvim --server "$1" --remote-expr 'getpid()' 2>/dev/null | tr -d '\r\n'; }

say "1. source assigns per-instance Cockpit socket names"
check "pid and item nonce are present" "$(grep -c 'cockpit-nvim-%1-%2.sock' TermView.cpp)" "1"
check "shared stable socket is absent" "$(grep -c 'cockpit-nvim.sock' TermView.cpp || true)" "0"
check "launch never unlinks its socket" "$(grep -E -c 'rm[[:space:]]+-f.*NVIM_LISTEN_ADDRESS' TermView.cpp || true)" "0"

say "2. every currently published Cockpit socket is live and uniquely owned"
live=0
owners=""
for socket in "$RT"/cockpit-nvim-*.sock; do
  [ -S "$socket" ] || continue
  owner=$(who "$socket")
  [ -n "$owner" ] || continue
  live=$((live + 1))
  owners="$owners $owner"
done
check "at least one live Cockpit nvim" "$([ "$live" -ge 1 ] && echo yes || echo no)" "yes"
unique=$(printf '%s\n' $owners | sed '/^$/d' | sort -u | wc -l)
check "each live socket has a unique nvim" "$unique" "$live"

say "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
