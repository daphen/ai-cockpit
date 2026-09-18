#!/usr/bin/env bash
# validate-qml.sh — does the shell PARSE, without touching a running cockpit.
#
# `run-qs.sh` is not a validator: it kills the instance of its mode before launching, so
# using it as a syntax check restarts David's cockpit every time (which is exactly what
# happened while iterating on the rail). And the journal is no help either — a running
# shell keeps serving its cached QML, so a broken file on disk logs nothing at all.
#
# So: copy the shell to a throwaway path, load it OFFSCREEN under a distinct title (the
# kill sweep matches on COCKPIT_TITLE, so nothing else is touched), print any errors, and
# tear it down.
set -uo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d /tmp/qml-validate.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cp -r qs-shell "$tmp/shell"
mkdir -m 700 "$tmp/runtime" "$tmp/home"

log=$tmp/out.log
env -u WAYLAND_DISPLAY -u DISPLAY -u NVIM_LISTEN_ADDRESS -u COCKPIT_NVIM_SOCK -u HEIDR_NVIM_SOCK -u VIMINIT -u EXINIT \
HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" \
QT_QPA_PLATFORM=offscreen COCKPIT_INSTANCE="qml-validate-$$" COCKPIT_COCKPIT_CMD=cat COCKPIT_AGENTD_SOCKS="$tmp/absent.sock" \
COCKPIT_TITLE="qml-validate-$$" \
COCKPIT_SCOPE="${COCKPIT_SCOPE:-lovable}" \
COCKPIT_ASSET_DIR="$PWD/assets" \
QML2_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml" \
QML_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml" \
  timeout 25 qs -p "$tmp/shell" >"$log" 2>&1 &
pid=$!

# Errors surface within the first seconds; a clean load just keeps running.
for _ in $(seq 1 40); do
    if grep -qE "ERROR|Syntax error|unavailable|^Error in VIMINIT" "$log" 2>/dev/null; then
        echo "FAIL — $(basename "$0"):"
        grep -iE "ERROR|Syntax error|unavailable|caused by" "$log" | head -8
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        exit 1
    fi
    grep -q "Configuration Loaded" "$log" 2>/dev/null && break
    sleep 0.25
done

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
if grep -qE "ERROR|Syntax error|unavailable|^Error in VIMINIT" "$log" 2>/dev/null; then
    echo "FAIL:"; grep -iE "ERROR|caused by" "$log" | head -8; exit 1
fi
if ! grep -q "Configuration Loaded" "$log"; then
    echo "FAIL — configuration did not finish loading"; exit 1
fi
echo "OK — shell loaded (offscreen, isolated runtime)"
