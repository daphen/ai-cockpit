import QtQuick
import Quickshell.Io

QtObject {
  id: root
  property var sessions: []
  property bool enabled: false
  property var states: ({})
  readonly property string subjects: JSON.stringify(sessions.map(s => ({name:s.name, cwd:s.cwd, plan:s.plan || ""})))
  readonly property bool active: enabled && sessions.length > 0
  onSubjectsChanged: refresh.restart()
  onActiveChanged: if (active) { states = ({}); refresh.restart() }
  property Timer refreshTimer: Timer {
    id: refresh
    interval: 250
    onTriggered: {
      if (!root.active) return
      if (poll.running) restart()
      else poll.running = true
    }
  }
  property Timer minuteTimer: Timer {
    interval: 60000; repeat: true; running: root.active
    onTriggered: refresh.restart()
  }
  property Process process: Process {
    id: poll
    command: ["python3", Qt.resolvedUrl("ticket-status.py").toString().replace(/^file:\/\//, ""), root.subjects]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.states = JSON.parse(text) } catch (_) { root.states = ({}) }
      }
    }
    onExited: (code, status) => { if (code !== 0) root.states = ({}) }
  }
}
