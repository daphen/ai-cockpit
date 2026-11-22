import QtQuick
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  property int turns: 3
  property var pending: []
  property int round: 0
  property var swapped: ({})
  property bool failed: false
  property var fetched: []
  property int keys: 0
  function find(item, name) {
    if (item.objectName === name) return item
    for (var c of item.children) { var hit = test.find(c, name); if (hit) return hit }
    return null
  }
  Timer { id: typist; interval: 150; repeat: true; onTriggered: { test.find(rail, "composerInput").text += "x"; if (++test.keys >= 16) stop() } }
  function check(ok, message) { if (!ok && !failed) { failed = true; console.error("Error: " + message); Qt.exit(1) } }
  function transcript(sid) {
    var entries = [], parent = null, n = sid === "beta" ? test.turns : 3
    for (var i = 0; i < n; i++) {
      entries.push({ type: "message", id: sid + "u" + i, parentId: parent, message: { role: "user", timestamp: i * 10, content: [{ type: "text", text: sid + " question " + i }] } })
      entries.push({ type: "message", id: sid + "a" + i, parentId: sid + "u" + i, message: { role: "assistant", timestamp: i * 10 + 5, content: [{ type: "text", text: sid + " answer " + i }] } })
      parent = sid + "a" + i
    }
    return JSON.stringify({ type: "response", command: "get_entries", success: true, session: sid, data: { entries: entries, leafId: parent } })
  }
  // A real transcript fetch takes a few hundred ms; replying instantly hides the race.
  AgentdState {
    id: state
    selectedSession: rail.selectedRaw
    function send(message) {
      if (message.type === "get_entries") { var sid = message.session; test.fetched.push(sid); test.pending.push(sid); later.restart() }
      return true
    }
  }
  Timer { id: later; interval: 250; onTriggered: { var list = test.pending; test.pending = []; for (var sid of list) state.onLine(test.transcript(sid), 0) } }
  FloatingWindow {
    visible: true; implicitWidth: 720; implicitHeight: 900
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "switch-bg-test"; focused: true }
  }
  function newestText() {
    var feed = rail.groupedFeed, last = feed[feed.length - 1]
    return last ? JSON.stringify(last).match(/(alpha|beta) answer \d+/g) : null
  }
  // What the switch shows the moment it swaps sessions must already be current.
  Connections {
    target: rail
    function onShownRawChanged() { Qt.callLater(() => { test.swapped[rail.shownRaw] = String(test.newestText()) }) }
  }
  function betaFinishesTurn() {
    test.turns++
    var i = test.turns - 1
    state.onLine(JSON.stringify({ type: "message_end", session: "beta", message: { role: "user", timestamp: i * 10, content: [{ type: "text", text: "beta question " + i }] } }), 0)
    state.onLine(JSON.stringify({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: i * 10 + 5, content: [{ type: "text", text: "beta answer " + i }] } }), 0)
    state.onLine(JSON.stringify({ type: "agent_end", session: "beta", messages: [] }), 0)
  }
  Timer {
    interval: 1200; repeat: true; running: true
    onTriggered: {
      var r = test.round++
      if (r === 0) {
        state.onLine(JSON.stringify({ type: "roster", sessions: [{ id: "alpha", name: "alpha", cwd: "/tmp", status: "idle" }, { id: "beta", name: "beta", cwd: "/tmp", status: "idle" }] }), 0)
        rail.activeRaw = "beta"
      } else if (r === 1) {
        rail.activeRaw = "alpha"
      } else if (r === 2) {
        test.betaFinishesTurn()
      } else if (r === 4) {
        test.swapped = ({})
        rail.activeRaw = "beta"
      } else if (r === 5) {
        test.check(test.swapped.beta && test.swapped.beta.indexOf("beta answer 3") >= 0, "a turn beta finished in the background was missing when the switch showed it: " + test.swapped.beta)
        rail.activeRaw = "alpha"
      } else if (r === 6) {
        test.betaFinishesTurn()
        test.swapped = ({})
        rail.activeRaw = "beta"
      } else if (r === 8) {
        test.check(test.swapped.beta && test.swapped.beta.indexOf("beta answer 4") >= 0, "switching right after beta's turn showed its old cards, then updated: " + test.swapped.beta)
        rail.activeRaw = "alpha"
      } else if (r === 9) {
        typist.start()
        test.betaFinishesTurn()
        test.fetched = []
      } else if (r === 10) {
        test.check(test.fetched.indexOf("beta") < 0, "a background transcript fetch ran while the user was typing")
      } else if (r === 14) {
        test.check(test.fetched.indexOf("beta") >= 0, "the background refresh never ran after typing paused")
      } else if (r === 15) {
        test.turns++
        var i = test.turns - 1
        state.onLine(JSON.stringify({ type: "message_end", session: "beta", message: { role: "assistant", timestamp: i * 10 + 5, content: [{ type: "text", text: "beta answer " + i }] } }), 0)
      } else if (r === 17) {
        state.onLine(JSON.stringify({ type: "message_update", session: "beta", assistantMessageEvent: { type: "text_delta", delta: "still going" } }), 0)
        test.fetched = []
        test.swapped = ({})
        rail.activeRaw = "beta"
      } else if (r === 18) {
        test.check(test.swapped.beta && test.swapped.beta.indexOf("beta answer 6") >= 0, "a step beta saved mid-turn was missing when the switch showed it: " + test.swapped.beta)
        test.check(test.fetched.indexOf("beta") < 0, "switching to a running session still waited on a fetch although its background copy was current")
        if (!test.failed) console.log("PASS: background sessions stay current through and between turns, so a switch shows them at once, and refreshes wait for typing to pause")
        Qt.quit()
      }
    }
  }
}
