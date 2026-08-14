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

# MODE by launch context. The DEFAULT is PRIVATE: the personal scope only, files and
# sessions all on this machine. Launching from the lovable workspace is the special
# case that wires the full work cockpit — local lovable scope (orchestrator + PR
# reviewers) first, the tunneled VM work scope, then personal LAST: on a name
# collision the earlier socket wins, and ticket names must stay addressable.
if [ -z "${HEIDR_AGENTD_SOCKS:-}" ] && [ -z "${HEIDR_AGENTD_SOCK:-}" ]; then
  ws=$(niri msg --json workspaces 2>/dev/null | jq -r '.[] | select(.is_focused) | .name // empty' 2>/dev/null || true)
  case "${ws:-}" in
    lovable*)
      scopes="lovable work personal"
      export HEIDR_SCOPE="${HEIDR_SCOPE:-lovable}"
      export HEIDR_NEW_CWD="${HEIDR_NEW_CWD:-$HOME/work/lovable}"
      ;;
    *)
      scopes="personal"
      export HEIDR_SCOPE="${HEIDR_SCOPE:-personal}"
      export HEIDR_NEW_CWD="${HEIDR_NEW_CWD:-$HOME/personal}"
      ;;
  esac
  socks=""
  # Paths included even before the daemon binds: the rail re-dials every 2s, so a
  # cold daemon just connects late instead of being silently absent forever.
  for sc in $scopes; do socks="${socks:+$socks,}${XDG_RUNTIME_DIR}/agentd-${sc}.sock"; done
  export HEIDR_AGENTD_SOCKS="$socks"
  echo "mode=${HEIDR_SCOPE} HEIDR_AGENTD_SOCKS=$HEIDR_AGENTD_SOCKS"
fi

export QML2_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export QML_IMPORT_PATH="$QML2_IMPORT_PATH"
export LD_LIBRARY_PATH="$PWD/build:${LD_LIBRARY_PATH:-}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
echo "QML_IMPORT_PATH=$QML_IMPORT_PATH"
exec qs -p "$PWD/qs-shell"
