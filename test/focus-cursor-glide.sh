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
    property var glides: []
    Connections {
      target: caretGlide
      function onRunningChanged() {
        if (caretGlide.running) win.glides.push({ x: glideX.from, y: glideY.from, tx: glideX.to, ty: glideY.to,
          held: !term.active && rail.caretHeld, landing: glideCaret.landing })
      }
    }
    Timer {
      property int stage: 0
      property var expect: null
      interval: 400; repeat: true; running: true
      function near(a, b) { return Math.abs(a - b) < 0.5 }
      function check(label, from, to, held, landing) {
        const g = win.glides.shift()
        if (!g) throw new Error(label + ": no glide")
        if (win.glides.length) throw new Error(label + ": more than one glide")
        if (!near(g.x, from.x) || !near(g.y, from.y)) throw new Error(label + ": wrong start")
        if (!near(g.tx, to.x) || !near(g.ty, to.y)) throw new Error(label + ": wrong landing")
        if (g.held !== held || g.landing !== landing) throw new Error(label + ": wrong cursor hand-off")
        if (caretGlide.running || glideCaret.visible) throw new Error(label + ": still flying")
      }
      onTriggered: {
        const c = glideCaret
        if (stage === 0) term.forceActiveFocus()
        else if (stage === 1) {
          if (!term.active || term.cursorRect.height <= 0) throw new Error("focused terminal shows no published cursor")
          expect = [c.target("nvim")]
          win.pane = "rail"; rail.composerField.forceActiveFocus()
          if (!rail.caretHeld) throw new Error("composer caret showed before the glide started")
        } else if (stage === 2) {
          check("nvim to composer", expect[0], c.target("composer"), true, "caret")
          if (rail.caretHeld) throw new Error("composer caret still held")
          expect = [c.target("composer")]
          win.pane = "nvim"; term.forceActiveFocus()
          if (term.active) throw new Error("terminal cursor showed before the glide started")
        } else if (stage === 3) {
          check("composer to nvim", expect[0], c.target("nvim"), true, "caret")
          if (!term.active) throw new Error("terminal cursor did not return after the glide")
          rail.workspaceTab = "dashboard"; chin.st = ({ dashboard: { active: true, model: { kind: "session", cards: [{ title: "CHANGES", rows: [{ text: "flake.nix", action: "open:flake.nix" }] }] } } })
        } else if (stage === 4) {
          if (!dashboard.activeFocus) throw new Error("dashboard did not take focus")
          win.pane = "rail"; rail.composerField.forceActiveFocus()
        } else if (stage === 5) {
          win.glides = []
          expect = [c.target("composer")]
          win.pane = "nvim"
        } else if (stage === 6) {
          check("composer to dashboard row", expect[0], c.target("dashboard"), true, "rest")
          const row = dashboard.findRow(dashboard), r = row && row.mapToItem(c.parent, 0, 0)
          if (!r || Math.abs(c.target("dashboard").y - (r.y + row.height / 2)) > 1 || c.target("dashboard").x >= r.x) throw new Error("dashboard glide did not land on the focused row")
          const dot = dashboard.children.find(k => k.objectName === "dashRestDot"), d = dot && dot.mapToItem(c.parent, 4, 4)
          if (!dot || !dot.visible || !near(d.x, c.target("dashboard").x) || !near(d.y, c.target("dashboard").y)) throw new Error("dashboard dot vanished after landing")
          if (term.active) throw new Error("dashboard focus turned the terminal cursor on")
          console.log("PASS: focus glides a dot between Neovim, the focused dashboard row and composer, one cursor at a time")
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
