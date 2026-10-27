#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/cockpit-focus-glide.XXXXXX)
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
      interval: 250; repeat: true; running: true
      onTriggered: {
        const caret = glideCaret
        const near = (a, b) => Math.abs(a - b) < 0.5
        if (stage === 0) term.forceActiveFocus()
        else if (stage === 1) {
          if (!term.active || term.cursorRect.height <= 0) throw new Error("focused terminal shows no published cursor")
          win.pane = "rail"; rail.composerField.forceActiveFocus()
          if (!caretGlide.running || term.active || !rail.caretHeld)
            throw new Error("Neovim to composer did not glide with both real cursors hidden")
          const from = caret.caret("nvim")
          if (!near(glideX.from, from.x) || !near(glideY.from, from.y)) throw new Error("glide did not start at the Neovim cursor")
        } else if (stage === 2) {
          const to = caret.caret("composer")
          if (caretGlide.running || caret.visible || rail.caretHeld) throw new Error("glide did not hand over to the composer caret")
          if (!near(caret.x, to.x) || !near(caret.y, to.y)) throw new Error("glide did not land on the composer caret")
          win.pane = "nvim"; term.forceActiveFocus()
          if (!caretGlide.running || term.active) throw new Error("composer to Neovim did not glide")
        } else if (stage === 3) {
          const to = caret.caret("nvim")
          if (caretGlide.running || !term.active) throw new Error("terminal cursor did not return after the glide")
          if (!near(caret.x, to.x) || !near(caret.y, to.y)) throw new Error("glide did not land on the Neovim cursor")
          rail.workspaceTab = "dashboard"; chin.st = ({ dashboard: { active: true, model: {} } })
        } else if (stage === 4) {
          dashboard.forceActiveFocus()
          if (caretGlide.running || term.active) throw new Error("dashboard focus glided or left the terminal cursor on")
          console.log("PASS: focus glides between Neovim and composer carets, one cursor at a time")
          Qt.quit()
        }
        stage++
      }
    }
'''+text[end:]
p.write_text(text)
PY
env -u WAYLAND_DISPLAY -u DISPLAY HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" \
  QT_QPA_PLATFORM=offscreen COCKPIT_INSTANCE="focus-glide-$$" COCKPIT_COCKPIT_CMD=cat \
  COCKPIT_AGENTD_SOCKS="$tmp/absent.sock" COCKPIT_SCOPE=personal \
  COCKPIT_ASSET_DIR="$PWD/assets" QML_IMPORT_PATH="$PWD/build/qml:$HOME/.local/share/qml" \
  timeout 12 qs -p "$tmp/ui" > "$tmp/log" 2>&1 || { grep -aE 'Error|PASS' "$tmp/log" | head -5; exit 1; }
if grep -E 'ERROR|Error:' "$tmp/log"; then exit 1; fi
grep 'PASS:' "$tmp/log"
