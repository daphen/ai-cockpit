#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/cockpit-editor-focus-tab.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cp -r qs-shell "$tmp/ui"
mkdir -m 700 "$tmp/runtime" "$tmp/home"
python3 - "$tmp/ui/shell.qml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text()
end=text.rfind('\n  }\n}')
assert end >= 0
text=text[:end]+'''
    Timer {
      property int stage: 0
      interval: 180; repeat: true; running: true
      onTriggered: {
        var marked = viewRow.children.filter(item => item.focusMark === true).length
        if (stage === 0) term.forceActiveFocus()
        else if (stage === 1) {
          if (!term.activeFocus || marked !== 1) throw new Error("focused editor does not mark exactly its active tab")
          win.pane = "rail"
          rail.enterInsert()
        } else if (stage === 2) {
          if (marked || term.activeFocus || !rail.insert)
            throw new Error("composer focus leaves the tab marked")
          rail.exitInsert()
        } else if (stage === 3) {
          if (marked) throw new Error("chat focus leaves the tab marked")
          win.pane = "nvim"
          term.forceActiveFocus()
        } else if (stage === 4) {
          if (marked !== 1) throw new Error("returning to editor does not restore the tab mark")
          rail.workspaceTab = "dashboard"; chin.st = ({ dashboard: { active: true, model: {} } })
        } else if (stage === 5) {
          dashboard.forceActiveFocus()
        } else if (stage === 6) {
          if (!dashboard.activeFocus || marked !== 1) throw new Error("focused dashboard does not mark its tab")
          console.log("PASS: active view tab marks focus for editor, dashboard, composer and chat focus")
          Qt.quit()
        }
        stage++
      }
    }
'''+text[end:]
p.write_text(text)
PY
env -u WAYLAND_DISPLAY -u DISPLAY HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" \
  QT_QPA_PLATFORM=offscreen COCKPIT_INSTANCE="editor-focus-tab-$$" COCKPIT_COCKPIT_CMD=cat \
  COCKPIT_AGENTD_SOCKS="$tmp/absent.sock" COCKPIT_SCOPE=personal \
  COCKPIT_ASSET_DIR="$PWD/assets" QML_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml" \
  timeout 12 qs -p "$tmp/ui" > "$tmp/log" 2>&1 || { grep -aE "Error|PASS" "$tmp/log" | head -5; exit 1; }
if grep -E 'ERROR|Error:' "$tmp/log"; then exit 1; fi
grep 'PASS:' "$tmp/log"
