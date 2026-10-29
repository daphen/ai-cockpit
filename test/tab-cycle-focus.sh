#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/cockpit-tab-cycle.XXXXXX)
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
    property int editorJumps: 0
    Connections { target: rail; function onFocusNvim() { win.editorJumps++ } }
    Timer {
      property int stage: 0
      interval: 300; repeat: true; running: true
      onTriggered: {
        if (stage === 0) { win.pane = "rail"; rail.composerField.forceActiveFocus() }
        else if (stage === 1) {
          if (!rail.composerField.activeFocus) throw new Error("composer did not take focus")
          viewTabs.cycle(1)
          viewTabs.cycle(-1)
        } else if (stage === 2) {
          if (win.editorJumps) throw new Error("tab shortcut asked to focus the editor")
          if (!rail.composerField.activeFocus || win.pane !== "rail") throw new Error("tab shortcut moved focus out of the composer")
          console.log("PASS: Ctrl+Shift+H/L keep focus in the composer")
          Qt.quit()
        }
        stage++
      }
    }
'''+text[end:]
p.write_text(text)
PY
env -u WAYLAND_DISPLAY -u DISPLAY HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" \
  QT_QPA_PLATFORM=offscreen COCKPIT_INSTANCE="tab-cycle-$$" COCKPIT_COCKPIT_CMD=cat \
  COCKPIT_AGENTD_SOCKS="$tmp/absent.sock" COCKPIT_SCOPE=personal \
  COCKPIT_ASSET_DIR="$PWD/assets" QML_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml" \
  timeout 12 qs -p "$tmp/ui" > "$tmp/log" 2>&1 || { grep -aE 'Error|PASS' "$tmp/log" | head -5; exit 1; }
if grep -E 'ERROR|Error:' "$tmp/log"; then exit 1; fi
grep 'PASS:' "$tmp/log"
