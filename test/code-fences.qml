import QtQuick
import Quickshell
import QsLib
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property var codes: ["notes-cli -pull", "const tone = 1", "echo shell"]
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 900
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "code-fences-test" }
  }
  function texts(item, out) {
    if (!item || item.visible === false) return out
    if (typeof item.getText === "function" && item.length !== undefined) out.push(item.getText(0, item.length))
    else if (typeof item.text === "string") out.push(item.text)
    for (var child of item.children || []) texts(child, out)
    return out
  }
  Timer {
    interval: 200; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]}),0)
        rail.jumpToSession("worker")
        var text = "Run this:\n\n```\n" + test.codes[0] + "\n```\n\nThen:\n\n```typescript\n" + test.codes[1] + "\n```\n\nAnd:\n\n```bash\n" + test.codes[2] + "\n```\n\nDone."
        state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"worker",data:{leafId:"a",entries:[
          {id:"a",parentId:null,type:"message",message:{role:"assistant",content:[{type:"text",text:text}]}}
        ]}}),0)
      } else if (test.phase === 3) {
        var shown = test.texts(rail, [])
        var missing = test.codes.filter(code => !shown.some(t => t.indexOf(code) >= 0))
        if (missing.length) throw new Error("code blocks not rendered: " + JSON.stringify(missing))
        if (!shown.some(t => t === "code") || !shown.some(t => t.indexOf("typescript") === 0)) throw new Error("non-shell code blocks lack their label")
        console.log("PASS: untagged, typed and shell code blocks all render")
        Qt.quit()
      }
      test.phase++
    }
  }
}
