#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/cockpit-editor-outline.XXXXXX)
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
        var outline = paneLayout.children.find(item => item.objectName === "editorFocusOutline")
        if (stage === 0) term.forceActiveFocus()
        else if (stage === 1) {
          if (!term.activeFocus || !outline.visible || outline.border.width !== 1 || !Qt.colorEqual(outline.border.color, Qt.alpha(Theme.fg, 0.6)))
            throw new Error("focused editor lacks its ink outline")
          if (outline.x !== termCol.x || outline.y !== termCol.y || outline.width !== termCol.width || outline.height !== termCol.height)
            throw new Error("outline does not wrap the whole editor pane")
          win.pane = "rail"
          rail.enterInsert()
        } else if (stage === 2) {
          if (outline.visible || term.activeFocus || !rail.insert)
            throw new Error("composer focus leaves editor outline visible")
          rail.exitInsert()
        } else if (stage === 3) {
          if (outline.visible) throw new Error("chat focus leaves editor outline visible")
          win.pane = "nvim"
          term.forceActiveFocus()
        } else if (stage === 4) {
          if (!outline.visible) throw new Error("returning to editor does not restore outline")
          rail.workspaceTab = "dashboard"; chin.st = ({ dashboard: { active: true, model: {} } })
        } else if (stage === 5) {
          dashboard.forceActiveFocus()
        } else if (stage === 6) {
          if (!dashboard.activeFocus || !outline.visible) throw new Error("focused dashboard lacks the pane outline")
          console.log("PASS: real embedded terminal outline follows editor, dashboard, composer and chat focus")
          Qt.quit()
        }
        stage++
      }
    }
'''+text[end:]
p.write_text(text)
PY
env -u WAYLAND_DISPLAY -u DISPLAY HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" \
  QT_QPA_PLATFORM=offscreen COCKPIT_INSTANCE="editor-outline-$$" COCKPIT_COCKPIT_CMD=cat \
  COCKPIT_AGENTD_SOCKS="$tmp/absent.sock" COCKPIT_SCOPE=personal \
  COCKPIT_ASSET_DIR="$PWD/assets" QML_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml" \
  timeout 12 qs -p "$tmp/ui" > "$tmp/log" 2>&1 || { grep -aE "Error|PASS" "$tmp/log" | head -5; exit 1; }
if grep -E 'ERROR|Error:' "$tmp/log"; then exit 1; fi
grep 'PASS:' "$tmp/log"
