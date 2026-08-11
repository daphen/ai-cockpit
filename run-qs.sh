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
qs kill -p "$PWD/qs-shell" >/dev/null 2>&1 || true

export QML2_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export QML_IMPORT_PATH="$QML2_IMPORT_PATH"
export LD_LIBRARY_PATH="$PWD/build:${LD_LIBRARY_PATH:-}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
echo "QML_IMPORT_PATH=$QML_IMPORT_PATH"
exec qs -p "$PWD/qs-shell"
