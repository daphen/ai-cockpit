#!/usr/bin/env bash
# Dev loop for the C++ side: rebuild the plugin, then relaunch qs against the
# WORKING-TREE qs-shell (so QML hot-reloads on save; only C++ needs this script).
#   ./dev.sh            rebuild plugin + relaunch
#   ./dev.sh --no-build  just relaunch (QML-only tweaks hot-reload without even this)
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" != "--no-build" ]; then
  # Stop the old instance BEFORE relinking: the running one has the plugin .so mapped, and
  # overwriting it under itself put the cockpit in a crash-restart loop. run-qs.sh clears
  # survivors too, but by then the build has already happened.
  qs kill -p "$PWD/qs-shell" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6; do
    # awk, not grep: a grep in the pipeline shows up in ps's own output and matches itself
    [ -z "$(ps -eo args= | awk -v p="-p $PWD/qs-shell" 'index($0,p) && !/awk/')" ] && break
    sleep 0.5
  done
  echo "· building plugin…"
  nix-shell --run 'cmake --build build -j' || {
    echo "no build/ yet — configuring first"; \
    nix-shell --run 'cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -G Ninja && cmake --build build -j'; }
fi

exec ./run-qs.sh
