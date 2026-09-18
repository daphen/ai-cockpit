#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "qs-shell/shell.qml"
probe = '''
    TestEvent { id: focusKeys }
    TextInput { id: focusDecoy; width: 1; height: 1 }
    property int focusPhase: 0
    function focusCheck(ok, message) { if (!ok) throw new Error(message) }
    Timer { interval: 180; repeat: true; running: true; onTriggered: {
      try {
        if (win.focusPhase === 0) {
          personalAgentd.onLine(JSON.stringify({type:"roster",sessions:["alpha","beta","gamma"].map(n=>({id:n,name:n,cwd:"/tmp",status:"idle"}))}),0)
          rail.jumpToSession("alpha"); rail.prefillComposer("draft stays")
        } else if (win.focusPhase === 1) {
          focusIpc.focusRoster(); focusDecoy.forceActiveFocus()
          win.focusCheck(focusIpc.rosterHop() === "parked", "parked hop contract changed")
          focusKeys.keyClick(Qt.Key_J, Qt.NoModifier, 0)
          win.focusCheck(rail.cur === 1, "parked roster hop failed to take keyboard focus")
          focusIpc.focusRoster()
          win.focusCheck(focusIpc.rosterToggle() === "collapsed", "roster did not collapse")
          win.focusCheck(focusIpc.rosterToggle() === "landed", "roster did not reopen")
        } else if (win.focusPhase === 2) {
          win.focusCheck(!rail.insert, "stale composer callback stole roster focus")
          focusKeys.keyClick(Qt.Key_J, Qt.NoModifier, 0)
          win.focusCheck(rail.cur === 1, "reopened roster did not receive navigation")
          win.focusCheck(rail.composerText === "draft stays", "navigation edited the draft")
          focusIpc.focusLeft()
          chin.st = {dashboard:{active:true,model:{kind:"home",scope:"personal",identity:"HOME",cards:[],actions:[],tabs:[]}}}
          win.focusCheck(win.dashboardActive, "dashboard transition did not occur")
          focusIpc.rosterHop()
        } else if (win.focusPhase === 3) {
          win.focusCheck(win.pane === "rail", "late dashboard transition stole roster focus")
          focusKeys.keyClick(Qt.Key_J, Qt.NoModifier, 0)
          win.focusCheck(rail.cur === 1, "roster lost keyboard after dashboard transition")
          console.log("PASS: production roster IPC owns keyboard after parked hop, rapid reopen and dashboard transition")
          running = false; Qt.quit()
        }
        win.focusPhase++
      } catch (error) { console.error("TESTFAIL: " + error); running = false; Qt.quit() }
    } }
'''
with tempfile.TemporaryDirectory(prefix="cockpit-roster-offscreen-") as temporary:
    path = Path(temporary)
    for file in (root / "qs-shell").glob("*.qml"):
        shutil.copy2(file, path / file.name)
    text = source.read_text().replace("import QtQuick\n", "import QtQuick\nimport QtTest\n", 1)
    text = text.replace("id: win", "id: win" + probe, 1).replace("IpcHandler {", "IpcHandler { id: focusIpc", 1)
    (path / "shell.qml").write_text(text)
    env = os.environ.copy()
    for key in ["WAYLAND_DISPLAY", "DISPLAY"]:
        env.pop(key, None)
    env.update(HOME=temporary, QT_QPA_PLATFORM="offscreen", COCKPIT_COCKPIT_CMD="cat", COCKPIT_INSTANCE="roster-test", COCKPIT_SCOPE="personal",
               COCKPIT_AGENTD_SOCKS=str(path / "absent.sock"), LD_LIBRARY_PATH=str(root / "build"),
               QML_IMPORT_PATH=str(root / "build/qml") + ":" + str(Path.home() / ".local/share/qml"),
               QML2_IMPORT_PATH=str(root / "build/qml") + ":" + str(Path.home() / ".local/share/qml"))
    result = subprocess.run(["qs", "-p", temporary], env=env, capture_output=True, text=True, timeout=8)
    output = result.stdout + result.stderr
    print("\n".join(line for line in output.splitlines() if "PASS:" in line or "TESTFAIL:" in line or "ERROR" in line))
    sys.exit(0 if "PASS:" in output and "TESTFAIL:" not in output else 1)
