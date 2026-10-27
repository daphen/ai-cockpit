#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
real_home=$HOME
runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
state="$real_home/.local/state/cockpit/rail-presentation"
mode=${1:-}
[[ "$mode" != --check ]] || state="$state/check"
[[ -z "$mode" || "$mode" == --check ]] || { echo "Usage: $0 [--check]" >&2; exit 2; }
[[ -f "$root/build/qml/Heidr/libheidr_termplugin.so" ]] || { echo "Existing Cockpit QML plugin missing; build the development tree first." >&2; exit 1; }
mkdir -p "$state/home/.config" "$state/runtime"
chmod 700 "$state" "$state/home" "$state/runtime"
if [[ -f "$real_home/.config/theme_mode" ]]; then
  ln -sfn "$real_home/.config/theme_mode" "$state/home/.config/theme_mode"
fi
export HOME="$state/home"
export XDG_RUNTIME_DIR="$state/runtime"
export QML_IMPORT_PATH="$root/build/qml:$real_home/.local/share/qml"
export QML2_IMPORT_PATH="$QML_IMPORT_PATH"
export COCKPIT_INSTANCE=rail-presentation
export COCKPIT_ASSET_DIR="$root/assets"
unset COCKPIT_AGENTD_SOCKS COCKPIT_AGENTD_SOCK HEIDR_AGENTD_SOCKS HEIDR_AGENTD_SOCK
unset COCKPIT_NVIM_SOCK HEIDR_NVIM_SOCK NVIM_LISTEN_ADDRESS
if [[ "$mode" == --check ]]; then
  unset WAYLAND_DISPLAY DISPLAY
  export QT_QPA_PLATFORM=offscreen COCKPIT_PRESENTATION_CHECK=1
  log="$state/check.log"
  timeout 20 qs -p "$root/presentation" >"$log" 2>&1
  if grep -E 'Error:|ERROR|TypeError:|ReferenceError:' "$log"; then exit 1; fi
  grep 'PASS:' "$log"
else
  unset COCKPIT_PRESENTATION_CHECK
  if [[ -n "${WAYLAND_DISPLAY:-}" && "$WAYLAND_DISPLAY" != /* ]]; then
    export WAYLAND_DISPLAY="$runtime/$WAYLAND_DISPLAY"
  elif [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
    for display in "$runtime"/wayland-*; do
      [[ -S "$display" ]] || continue
      export WAYLAND_DISPLAY="$display"
      break
    done
  fi
  [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]] || { echo "No desktop display found." >&2; exit 1; }
  exec qs -p "$root/presentation"
fi
