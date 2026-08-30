#!/usr/bin/env bash
# Run Cockpit inside Quickshell: the terminal plugin (TermView) + a QsLib
# sidebar in one qs window. qs is the system binary; the plugin resolves its
# own deps (libheidr_term, libghostty-vt) via RUNPATH, so no nix-shell needed.
set -euo pipefail
cd "$(dirname "$0")"
export COCKPIT_ASSET_DIR="$PWD/assets"
[ -f build/qml/Heidr/libheidr_termplugin.so ] || {
  echo "plugin missing — build first: nix-shell --run 'cmake --build build -j'"; exit 1; }

for v in SCOPE NEW_CWD AGENTD_SOCKS AGENTD_SOCK INSTANCE VM VM_USER VM_HOST DEMO DEV VENDORED_GHOSTTY; do
  cv="COCKPIT_$v"; hv="HEIDR_$v"
  if [ -n "${!cv:-}" ]; then export "$hv=${!cv}"
  elif [ -n "${!hv:-}" ]; then export "$cv=${!hv}"
  fi
done

requested_scope="${COCKPIT_SCOPE:-}"
if [ -z "${COCKPIT_INSTANCE:-}" ]; then
  case "$requested_scope" in
    lovable|work) COCKPIT_INSTANCE=work ;;
    personal)     COCKPIT_INSTANCE=personal ;;
    *)            COCKPIT_INSTANCE=main ;;
  esac
fi
export COCKPIT_INSTANCE
mode_file="$HOME/.local/state/cockpit/mode-$COCKPIT_INSTANCE"
if [ -z "$requested_scope" ] && [ -r "$mode_file" ]; then
  requested_scope=$(cat "$mode_file")
fi
case "$requested_scope" in
  lovable|work)
    export COCKPIT_SCOPE=lovable
    export COCKPIT_NEW_CWD="${COCKPIT_NEW_CWD:-$HOME/work/lovable}"
    default_socks="$XDG_RUNTIME_DIR/agentd-lovable.sock,$XDG_RUNTIME_DIR/agentd-work.sock"
    ;;
  *)
    export COCKPIT_SCOPE=personal
    export COCKPIT_NEW_CWD="${COCKPIT_NEW_CWD:-$HOME/personal}"
    default_socks="$XDG_RUNTIME_DIR/agentd-personal.sock"
    ;;
esac
export COCKPIT_AGENTD_SOCKS="${COCKPIT_AGENTD_SOCKS:-$default_socks}"
export COCKPIT_TITLE="cockpit-instance-$COCKPIT_INSTANCE"
echo "instance=$COCKPIT_INSTANCE mode=$COCKPIT_SCOPE"

# Config-path identity belongs to the window instance, not its current scope. Switching
# Personal ↔ Work must not turn one process into the other process's duplicate.
shellDir="$PWD/qs-shell"
if [ "$COCKPIT_INSTANCE" != "main" ]; then
  safe_instance=$(printf '%s' "$COCKPIT_INSTANCE" | tr -c 'A-Za-z0-9_-' '_')
  mirror="$HOME/.local/state/cockpit/instance-$safe_instance-shell"
  mkdir -p "$mirror"; rm -f "$mirror"/*.qml
  for f in "$PWD"/qs-shell/*.qml; do ln -s "$f" "$mirror/$(basename "$f")"; done
  shellDir="$mirror"
fi
for v in SCOPE NEW_CWD AGENTD_SOCKS AGENTD_SOCK TITLE VM VM_USER VM_HOST DEMO DEV VENDORED_GHOSTTY; do
  cv="COCKPIT_$v"; hv="HEIDR_$v"
  [ -n "${!cv:-}" ] && export "$hv=${!cv}"
done

# Clear only this stable instance. Its current Personal/Work selection is mutable.
qs kill -p "$shellDir" >/dev/null 2>&1 || true
# Argv is NOT a reliable identity: the qs launcher rewrites itself to a bare
# ".quickshell-wrapped" with no args, so a "-p <path>" scan misses it and the
# old instance survives every relaunch (new + old then fight over the same
# shell id and crash). Identify it by the stable instance environment.
survivors_of_mode() {
  for pid in $(pgrep -x qs; pgrep -x quickshell; pgrep -x '\.quickshell-wra'); do
    [ "$pid" = "$$" ] && continue
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qxF "COCKPIT_INSTANCE=$COCKPIT_INSTANCE"; then
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
# NO workspace placement here: a relaunch must come back on the workspace that was
# hosting it. Pinning it to the named `lovable` workspace yanked the cockpit off the
# workspace David had it on and stranded it above his stack (2026-08-25). Boot-time
# placement is cockpit-boot's job; a refresh happens in place.
# Per-ticket infrastructure (mutagen syncs, devenv stacks) outlives its ticket and
# keeps burning CPU; reap what no live session claims. Best-effort, never blocking,
# and it refuses to act when no agentd roster answers.
( "$HOME/.config/niri/scripts/cockpit-reap-stale" --yes >/dev/null 2>&1 & ) || true

exec qs -p "$shellDir"
