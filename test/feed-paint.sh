#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export COCKPIT_PAINT_DIR
COCKPIT_PAINT_DIR=$(mktemp -d /tmp/cockpit-feed-paint.XXXXXX)
trap 'rm -rf "$COCKPIT_PAINT_DIR"' EXIT
bash test/session-landing.sh test/feed-paint.qml
magick compare -metric AE "$COCKPIT_PAINT_DIR/incremental.png" "$COCKPIT_PAINT_DIR/reset.png" null:
printf '\nPASS: article selection preserves geometry; incremental and reset renders are pixel-identical\n'
