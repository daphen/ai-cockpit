#!/usr/bin/env bash
# Load the shell in an ISOLATED instance and report load errors, without touching the
# running cockpit. Quickshell hot-reloads, so a file that fails to parse leaves the OLD
# version live: the edit is invisible and every later diagnosis is about code that never
# ran. Run this after every QML write.
set -uo pipefail
cd "$(dirname "$0")"
probe="${TMPDIR:-/tmp}/qs-probe.$$"
log="$probe.log"
trap 'rm -rf "$probe" "$log"' EXIT
cp -r qs-shell "$probe" || exit 1
export COCKPIT_ASSET_DIR="$PWD/assets" COCKPIT_SCOPE=probe COCKPIT_DEMO=1
export QML2_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml"
export QML_IMPORT_PATH="$QML2_IMPORT_PATH"
timeout "${1:-15}" qs -p "$probe" -n > "$log" 2>&1
rc=$?
if grep -qiE "Failed to load|is not a type|Property value set|Cannot assign|Unable to assign|Expected token|is not installed" "$log"; then
  echo "✗ QML LOAD FAILED"; grep -iE "ERROR|caused by" "$log" | head -8; exit 1
fi
# 124 = still running when the timeout fired, i.e. it loaded and stayed up.
[ "$rc" -eq 124 ] && { echo "✓ loads clean (stayed up ${1:-15}s)"; exit 0; }
echo "✗ exited early (rc=$rc)"; tail -12 "$log"; exit 1
