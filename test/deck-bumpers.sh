#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/cockpit-deck-bumpers.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cp -r qs-shell "$tmp/ui"
mkdir -m 700 "$tmp/runtime" "$tmp/home"
python3 - "$tmp/ui/shell.qml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text()
text=text.replace('target: "cockpit"', 'id: cockpitIpc; target: "cockpit"', 1)
end=text.rfind('\n  }\n}')
assert end >= 0
text=text[:end]+'''
    Timer {
      property int stage: 0
      property var seen: []
      interval: 300; repeat: true; running: true
      onTriggered: {
        if (stage === 0) {
          var sessions = ["alpha", "bravo", "charlie"].map(n => ({ id: n, name: n, cwd: "/tmp", status: "idle" }))
          sessions.push({ id: "bravo-child", name: "bravo-child", cwd: "/tmp", parent: "bravo", status: "idle" })
          personalAgentd.onLine(JSON.stringify({ type: "roster", sessions: sessions }), 0)
          win.pane = "rail"; rail.activeRaw = "bravo-child"
        }
        else if (stage === 1) {
          cockpitIpc.step("next"); seen.push(rail.selectedRaw)
          cockpitIpc.step("next"); seen.push(rail.selectedRaw)
          cockpitIpc.step("prev"); seen.push(rail.selectedRaw)
          if (seen.join() !== "charlie,alpha,charlie") throw new Error("rail stepped " + seen.join())
          seen = [viewTabs.current]
          win.pane = "nvim"
        } else if (stage === 2) {
          cockpitIpc.step("next")
        } else if (stage === 3) {
          if (viewTabs.current === seen[0]) throw new Error("left pane tab did not change")
          if (rail.selectedRaw !== "charlie") throw new Error("left pane step changed session")
          cockpitIpc.step("prev")
        } else if (stage === 4) {
          if (viewTabs.current !== seen[0]) throw new Error("prev did not return to " + seen[0])
          console.log("PASS: bumpers step sessions in the rail and tabs in the left pane")
          Qt.quit()
        }
        stage++
      }
    }
'''+text[end:]
p.write_text(text)
PY
env -u WAYLAND_DISPLAY -u DISPLAY HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" \
  QT_QPA_PLATFORM=offscreen COCKPIT_INSTANCE="deck-bumpers-$$" COCKPIT_COCKPIT_CMD=cat \
  COCKPIT_AGENTD_SOCKS="$tmp/absent.sock" COCKPIT_SCOPE=personal \
  COCKPIT_ASSET_DIR="$PWD/assets" QML_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml" \
  timeout 12 qs -p "$tmp/ui" > "$tmp/log" 2>&1 || { grep -aE 'Error:' "$tmp/log" | head -3; exit 1; }
if grep -E 'ERROR|Error:' "$tmp/log"; then exit 1; fi
grep 'PASS:' "$tmp/log"
