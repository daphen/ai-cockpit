import QtQuick
import Quickshell
import QsLib
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property var destinations: ["https://example.com", "/tmp/pi-cockpit-output-comparison.md", "references/pi-cockpit-output-comparison.md", "file:///tmp/pi-cockpit-output-comparison.md"]
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 900
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "local-link-style-test" }
  }
  function findProse(item) {
    if (!item || item.visible === false) return null
    if (item.readOnly && item.textDocument && item.textFormat === TextEdit.MarkdownText && item.getText(0, item.length).indexOf("Reference") >= 0) return item
    for (var child of item.children || []) { var found = findProse(child); if (found) return found }
    return null
  }
  Timer {
    interval: 200; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]}),0)
        rail.jumpToSession("worker")
        var text = test.destinations.map(url => "[Reference](" + url + ")").join("\n\n")
        state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"worker",data:{leafId:"a",entries:[
          {id:"a",parentId:null,type:"message",message:{role:"assistant",content:[{type:"text",text:text}]}}
        ]}}),0)
      } else if (test.phase === 3) {
        var prose = test.findProse(rail)
        if (!prose) throw new Error("Rendered link prose missing")
        var plain = prose.getText(0, prose.length), from = 0, rows = []
        for (var i = 0; i < test.destinations.length; i++) {
          var pos = plain.indexOf("Reference", from), rect = prose.positionToRectangle(pos)
          if (pos < 0) throw new Error("Link label missing: " + test.destinations[i])
          rows.push({y:rect.y,height:rect.height})
          from = pos + "Reference".length
        }
        running = false
        prose.grabToImage(function(result) {
          if (!result.saveToFile(Quickshell.env("COCKPIT_LINK_CAPTURE"))) throw new Error("Link capture failed")
          console.log("PASS: captured web, absolute-path, relative-path, and file-URL links; LINK_STYLE " + JSON.stringify({mode:Theme.mode,color:rail.summaryHex,rows:rows}))
          Qt.quit()
        })
      }
      test.phase++
    }
  }
}
