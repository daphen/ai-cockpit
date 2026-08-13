#!/usr/bin/env bash
# Run the spike INSIDE Quickshell: the Heidr C++ plugin (TermView) + a QsLib
# sidebar in one qs window. qs is the system binary; the plugin resolves its
# own deps (libheidr_term, libghostty-vt) via RUNPATH, so no nix-shell needed.
set -euo pipefail
cd "$(dirname "$0")"
[ -f build/qml/Heidr/libheidr_termplugin.so ] || {
  echo "plugin missing — build first: nix-shell --run 'cmake --build build -j'"; exit 1; }

# Clear any stale cockpit instance for this exact config path (config-scoped,
# won't touch the bar) so a relaunch always shows the current QML.
# `qs kill -p` does not always take (and a survivor leaves a second window plus an
# ambiguous ipc registry entry, which silently breaks Ctrl+l / Super+T). Verify.
qs kill -p "$PWD/qs-shell" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6; do
  survivors=$(ps -eo pid=,args= | awk -v p="$PWD/qs-shell" '$0 ~ ("-p " p) && $0 !~ /awk/ {print $1}')
  [ -z "$survivors" ] && break
  sleep 0.5
done
for pid in ${survivors:-}; do
  [ "$(tr -d '\0' < /proc/$pid/comm 2>/dev/null)" = "qs" ] ||
  [ "$(tr -d '\0' < /proc/$pid/comm 2>/dev/null)" = ".quickshell-wra" ] || continue
  kill "$pid" 2>/dev/null || true
done

# Default the rail to every agentd we can see: the local `lovable` scope (the
# orchestrator + PR reviewers) first, then the tunneled lovbox if its socket is
# up. Order matters — on a name collision the earlier socket wins, which is what
# keeps the LOCAL `lovable` in the rail instead of the box's base session.
if [ -z "${HEIDR_AGENTD_SOCKS:-}" ] && [ -z "${HEIDR_AGENTD_SOCK:-}" ]; then
  socks=""
  for sc in lovable work; do
    s="${XDG_RUNTIME_DIR}/agentd-${sc}.sock"
    [ -S "$s" ] && socks="${socks:+$socks,}$s"
  done
  [ -n "$socks" ] && export HEIDR_AGENTD_SOCKS="$socks"
  echo "HEIDR_AGENTD_SOCKS=${HEIDR_AGENTD_SOCKS:-<none found>}"
fi

export QML2_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export QML_IMPORT_PATH="$QML2_IMPORT_PATH"
export LD_LIBRARY_PATH="$PWD/build:${LD_LIBRARY_PATH:-}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
echo "QML_IMPORT_PATH=$QML_IMPORT_PATH"
exec qs -p "$PWD/qs-shell"
