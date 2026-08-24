#!/usr/bin/env bash
# Run Cockpit inside Quickshell: the terminal plugin (TermView) + a QsLib
# sidebar in one qs window. qs is the system binary; the plugin resolves its
# own deps (libheidr_term, libghostty-vt) via RUNPATH, so no nix-shell needed.
set -euo pipefail
cd "$(dirname "$0")"
export COCKPIT_ASSET_DIR="$PWD/assets"
[ -f build/qml/Heidr/libheidr_termplugin.so ] || {
  echo "plugin missing — build first: nix-shell --run 'cmake --build build -j'"; exit 1; }

# MODE by launch context. The DEFAULT is PRIVATE: the personal scope only, files and
# sessions all on this machine. Launching from the lovable workspace is the special
# case that wires the work cockpit — local lovable scope (orchestrator + PR
# reviewers) first, then the tunneled VM work scope; private/personal sessions
# stay out of the work rail entirely (they have their own cockpit).
for v in SCOPE NEW_CWD AGENTD_SOCKS AGENTD_SOCK TITLE VM VM_USER VM_HOST DEMO DEV VENDORED_GHOSTTY; do
  cv="COCKPIT_$v"; hv="HEIDR_$v"
  if [ -n "${!cv:-}" ]; then export "$hv=${!cv}"
  elif [ -n "${!hv:-}" ]; then export "$cv=${!hv}"
  fi
done
if [ -z "${COCKPIT_AGENTD_SOCKS:-}" ] && [ -z "${COCKPIT_AGENTD_SOCK:-}" ]; then
  ws=$(niri msg --json workspaces 2>/dev/null | jq -r '.[] | select(.is_focused) | .name // empty' 2>/dev/null || true)
  case "${ws:-}" in
    lovable*)
      scopes="lovable work"
      export COCKPIT_SCOPE="${COCKPIT_SCOPE:-lovable}"
      export COCKPIT_NEW_CWD="${COCKPIT_NEW_CWD:-$HOME/work/lovable}"
      ;;
    *)
      scopes="personal"
      export COCKPIT_SCOPE="${COCKPIT_SCOPE:-personal}"
      export COCKPIT_NEW_CWD="${COCKPIT_NEW_CWD:-$HOME/personal}"
      ;;
  esac
  socks=""
  # Paths included even before the daemon binds: the rail re-dials every 2s, so a
  # cold daemon just connects late instead of being silently absent forever.
  for sc in $scopes; do socks="${socks:+$socks,}${XDG_RUNTIME_DIR}/agentd-${sc}.sock"; done
  export COCKPIT_AGENTD_SOCKS="$socks"
  echo "mode=${COCKPIT_SCOPE} COCKPIT_AGENTD_SOCKS=$COCKPIT_AGENTD_SOCKS"
fi

# Per-mode window identity + qs config-path identity, so a private and a work cockpit
# can run SIMULTANEOUSLY: same path = the kill-old sweep above takes down the other
# mode's instance, and identical titles leave cockpit-ipc unable to route to the focused
# window. The private mode runs a symlink MIRROR of qs-shell (same live QML, distinct
# path — the rail-nav harness pattern).
shellDir="$PWD/qs-shell"
if [ "${COCKPIT_SCOPE:-lovable}" = "personal" ]; then
  export COCKPIT_TITLE="${COCKPIT_TITLE:-cockpit-qs · private}"
  mirror="$HOME/.local/state/cockpit/private-shell"
  mkdir -p "$mirror"; rm -f "$mirror"/*.qml
  for f in "$PWD"/qs-shell/*.qml; do ln -s "$f" "$mirror/$(basename "$f")"; done
  shellDir="$mirror"
else
  export COCKPIT_TITLE="${COCKPIT_TITLE:-cockpit-qs · lovable}"
fi
for v in SCOPE NEW_CWD AGENTD_SOCKS AGENTD_SOCK TITLE VM VM_USER VM_HOST DEMO DEV VENDORED_GHOSTTY; do
  cv="COCKPIT_$v"; hv="HEIDR_$v"
  [ -n "${!cv:-}" ] && export "$hv=${!cv}"
done

# Clear a stale instance of THIS MODE only (config-path scoped): a relaunch must show
# the current QML, but the OTHER mode's cockpit keeps running — that is the whole point
# of per-mode config paths. `qs kill -p` does not always take; verify and escalate.
qs kill -p "$shellDir" >/dev/null 2>&1 || true
# Argv is NOT a reliable identity: the qs launcher rewrites itself to a bare
# ".quickshell-wrapped" with no args, so a "-p <path>" scan misses it and the
# old instance survives every relaunch (new + old then fight over the same
# shell id and crash). Identify by environment: only OUR launches carry this
# mode's COCKPIT_TITLE.
survivors_of_mode() {
  for pid in $(pgrep -x qs; pgrep -x quickshell; pgrep -x '\.quickshell-wra'); do
    [ "$pid" = "$$" ] && continue
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qxF "COCKPIT_TITLE=$COCKPIT_TITLE"; then
      echo "$pid"
    fi
  done
}
for _ in 1 2 3 4 5 6; do
  survivors=$(survivors_of_mode)
  [ -z "$survivors" ] && break
  for pid in $survivors; do kill "$pid" 2>/dev/null || true; done
  sleep 0.5
done

export QML2_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export QML_IMPORT_PATH="$QML2_IMPORT_PATH"
# Keep the vendored library explicit so cached plugins remain launchable across path moves.
export LD_LIBRARY_PATH="$PWD/build:$PWD/vendor/libghostty-vt/lib:${LD_LIBRARY_PATH:-}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
_user=$(id -un)
export PATH="/etc/profiles/per-user/$_user/bin:$HOME/.nix-profile/bin:$PATH:/run/current-system/sw/bin"
echo "QML_IMPORT_PATH=$QML_IMPORT_PATH"
exec qs -p "$shellDir"
