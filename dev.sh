#!/usr/bin/env bash
# Dev loop for the C++ side: rebuild the plugin, then relaunch qs against the
# WORKING-TREE qs-shell (so QML hot-reloads on save; only C++ needs this script).
#   ./dev.sh            rebuild plugin + relaunch
#   ./dev.sh --no-build  just relaunch (QML-only tweaks hot-reload without even this)
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" != "--no-build" ]; then
  echo "· building plugin…"
  nix-shell --run 'cmake --build build -j' || {
    echo "no build/ yet — configuring first"; \
    nix-shell --run 'cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -G Ninja && cmake --build build -j'; }
fi

exec ./run-qs.sh
