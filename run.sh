#!/usr/bin/env bash
# Run the spike on your real Wayland display.
# The raw binary needs QML2_IMPORT_PATH to include Qt's own qml modules (your shell
# profile points it only at QsLib), so derive them from the linked Qt libs.
set -euo pipefail
cd "$(dirname "$0")"
[ -x build/heidr-term-spike ] || { echo "not built — run: nix-shell --run 'cmake -S . -B build && cmake --build build -j'"; exit 1; }

nix-shell --run bash <<'NSH'
bin=./build/heidr-term-spike
roots=""
for lib in libQt6Quick libQt6Qml libQt6Gui; do
  p=$(ldd "$bin" 2>/dev/null | grep -oP "/nix/store/[^ ]*/${lib}\.so[^ ]*" | head -1)
  [ -n "$p" ] || continue
  d="$(dirname "$p")/qt-6/qml"        # <pkg>/lib/<lib>.so → <pkg>/lib/qt-6/qml
  [ -d "$d" ] && roots="$roots:$d"
done
export QML2_IMPORT_PATH="${roots#:}${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
echo "QML2_IMPORT_PATH=$QML2_IMPORT_PATH"
echo "launching on $QT_QPA_PLATFORM …"
exec "$bin"
NSH
