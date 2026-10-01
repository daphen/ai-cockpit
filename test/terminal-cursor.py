#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="cockpit-cursor-test-") as directory:
    work = Path(directory)
    shell = work / "shell"
    shutil.copytree(root / "qs-shell", shell)
    source = (shell / "shell.qml").read_text()
    before, after = source.rsplit("  }\n}", 1)
    (shell / "shell.qml").write_text(before + '''
    Timer {
      property int phase: 0
      interval: 150; repeat: true; running: true
      onTriggered: {
        if (phase === 0) term.forceActiveFocus()
        else if (phase === 1) {
          if (!term.activeFocus || !term.active) throw new Error("focused terminal cursor disabled")
          win.pane = "rail"; rail.forceActiveFocus()
        } else {
          if (term.activeFocus || !rail.activeFocus || !term.active)
            throw new Error("rail focus hid the terminal cursor")
          console.log("PASS: production shell keeps terminal cursor active while keyboard focus is in the rail")
          Qt.quit()
        }
        phase++
      }
    }
  }
}''' + after)
    (work / "runtime").mkdir(mode=0o700)
    (work / "home").mkdir()
    env = dict(os.environ)
    for key in ("WAYLAND_DISPLAY", "DISPLAY", "NVIM_LISTEN_ADDRESS", "COCKPIT_NVIM_SOCK", "HEIDR_NVIM_SOCK", "VIMINIT", "EXINIT"):
        env.pop(key, None)
    env.update(HOME=str(work / "home"), XDG_RUNTIME_DIR=str(work / "runtime"), QT_QPA_PLATFORM="offscreen",
               COCKPIT_INSTANCE="cursor-test", COCKPIT_TITLE="cursor-test", COCKPIT_SCOPE="personal",
               COCKPIT_COCKPIT_CMD="cat", COCKPIT_AGENTD_SOCKS=str(work / "absent.sock"),
               COCKPIT_ASSET_DIR=str(root / "assets"),
               QML_IMPORT_PATH=str(root / "build/qml") + ":" + str(Path.home() / ".local/share/qml"),
               QML2_IMPORT_PATH=str(root / "build/qml") + ":" + str(Path.home() / ".local/share/qml"))
    result = subprocess.run(["qs", "-p", str(shell)], env=env, capture_output=True, text=True, timeout=15)
    output = result.stdout + result.stderr
    assert result.returncode == 0 and "PASS:" in output, output
    assert "ERROR" not in output, output
    print(next(line for line in output.splitlines() if "PASS:" in line))
