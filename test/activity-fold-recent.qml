import QtQuick
import Quickshell
import "."
ShellRoot {
  AgentdState { id: state; function send(message) { return true } }
  FloatingWindow {
    visible: true; implicitWidth: 900; implicitHeight: 700
    ActivityStream { id: page; anchors.fill: parent; agentd: state; sessions: state.sessions }
  }
  function at(daysBack, h, m) { var d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - daysBack); return d.getTime() + (h * 60 + m) * 60000 }
  function ask(i, t) { return [{ key: "p" + i, sid: "s", at: t, kind: "prompt", from: "you", text: "Ask " + i },
                               { key: "o" + i, sid: "s", at: t + 60000, kind: "summary", text: "Did " + i }] }
  Timer {
    interval: 300; running: true
    onTriggered: {
      state._noteActivity([].concat(ask(1, at(5, 12, 0)), ask(2, at(2, 23, 50)), ask(3, at(1, 0, 20))))
      var heads = page.rows.filter(r => r.kind === "day" || r.kind === "fold").map(r => r.kind)
      var cards = page.rows.filter(r => r.kind === "card").length
      if (heads.join() !== "fold,day,day" || cards !== 2) {
        console.log("Error: work running past midnight collapsed into folded days: " + heads.join() + ", " + cards + " cards shown"); Qt.exit(1); return
      }
      console.log("PASS: days with work within six hours of the newest card stay open across midnight; older days fold")
      Qt.quit()
    }
  }
}
