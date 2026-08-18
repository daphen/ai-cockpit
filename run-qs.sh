#!/usr/bin/env bash
# Run the spike INSIDE Quickshell: the Heidr C++ plugin (TermView) + a QsLib
# sidebar in one qs window. qs is the system binary; the plugin resolves its
# own deps (libheidr_term, libghostty-vt) via RUNPATH, so no nix-shell needed.
set -euo pipefail
cd "$(dirname "$0")"
[ -f build/qml/Heidr/libheidr_termplugin.so ] || {
  echo "plugin missing — build first: nix-shell --run 'cmake --build build -j'"; exit 1; }

# MODE by launch context. The DEFAULT is PRIVATE: the personal scope only, files and
# sessions all on this machine. Launching from the lovable workspace is the special
# case that wires the work cockpit — local lovable scope (orchestrator + PR
# reviewers) first, then the tunneled VM work scope; private/personal sessions
# stay out of the work rail entirely (they have their own cockpit).
if [ -z "${HEIDR_AGENTD_SOCKS:-}" ] && [ -z "${HEIDR_AGENTD_SOCK:-}" ]; then
  ws=$(niri msg --json workspaces 2>/dev/null | jq -r '.[] | select(.is_focused) | .name // empty' 2>/dev/null || true)
  case "${ws:-}" in
    lovable*)
      scopes="lovable work"
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

# Per-mode window identity + qs config-path identity, so a private and a work cockpit
# can run SIMULTANEOUSLY: same path = the kill-old sweep above takes down the other
# mode's instance, and identical titles leave heidr-ipc unable to route to the focused
# window. The private mode runs a symlink MIRROR of qs-shell (same live QML, distinct
# path — the rail-nav harness pattern).
shellDir="$PWD/qs-shell"
# Rename transition: export COCKPIT_* twins of every HEIDR_* var so readers
# can migrate independently; the HEIDR_ set retires in a later pass.
for v in SCOPE NEW_CWD AGENTD_SOCKS AGENTD_SOCK TITLE VM VM_USER VM_HOST DEMO DEV VENDORED_GHOSTTY; do
  hv="HEIDR_$v"
  if [ -n "${!hv:-}" ]; then export "COCKPIT_$v=${!hv}"; fi
done

if [ "${HEIDR_SCOPE:-lovable}" = "personal" ]; then
  export HEIDR_TITLE="${HEIDR_TITLE:-heidr-qs · private}"
  mirror="$HOME/.local/state/heidr/private-shell"
  mkdir -p "$mirror"; rm -f "$mirror"/*.qml
  for f in "$PWD"/qs-shell/*.qml; do ln -s "$f" "$mirror/$(basename "$f")"; done
  shellDir="$mirror"
else
  export HEIDR_TITLE="${HEIDR_TITLE:-heidr-qs · lovable}"
fi
export COCKPIT_SCOPE="${COCKPIT_SCOPE:-$HEIDR_SCOPE}" COCKPIT_TITLE="${COCKPIT_TITLE:-$HEIDR_TITLE}" COCKPIT_NEW_CWD="${COCKPIT_NEW_CWD:-${HEIDR_NEW_CWD:-}}"

# Clear a stale instance of THIS MODE only (config-path scoped): a relaunch must show
# the current QML, but the OTHER mode's cockpit keeps running — that is the whole point
# of per-mode config paths. `qs kill -p` does not always take; verify and escalate.
qs kill -p "$shellDir" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6; do
  survivors=$(ps -eo pid=,args= | awk -v p="$shellDir" '$0 ~ ("-p " p) && $0 !~ /awk/ {print $1}')
  [ -z "$survivors" ] && break
  sleep 0.5
done
for pid in ${survivors:-}; do
  [ "$(tr -d '\0' < /proc/$pid/comm 2>/dev/null)" = "qs" ] ||
  [ "$(tr -d '\0' < /proc/$pid/comm 2>/dev/null)" = ".quickshell-wra" ] || continue
  kill "$pid" 2>/dev/null || true
done

export QML2_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export QML_IMPORT_PATH="$QML2_IMPORT_PATH"
export LD_LIBRARY_PATH="$PWD/build:${LD_LIBRARY_PATH:-}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
echo "QML_IMPORT_PATH=$QML_IMPORT_PATH"
exec qs -p "$shellDir"
