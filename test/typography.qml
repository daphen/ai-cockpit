import QtQuick
import Quickshell
import Heidr
import "."
ShellRoot {
  id: test
  property int phase: 0
  readonly property string paragraph: "A readable conversation uses regular type, clear spacing, and calm emphasis. It should wrap without feeling crowded."
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow { visible: true; width: 720; height: 1200
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "typography-proof" }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function find(item, predicate) {
    if (predicate(item)) return item
    for (var child of item.children || []) { var found = find(child, predicate); if (found) return found }
    return null
  }
  Timer { interval: 250; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]}),0)
        rail.jumpToSession("worker")
        state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"worker",data:{entries:[
          {id:"u",type:"message",message:{role:"user",content:[{type:"text",text:"Show me the typography"}]}},
          {id:"a",parentId:"u",type:"message",message:{role:"assistant",content:[{type:"text",text:test.paragraph + "\n\n**Clear emphasis.** A second paragraph with a <https://example.com> link.\n\n- A compact list with enough text to wrap onto a second line and demonstrate that continuation lines hang under the item text rather than under the bullet.\n- Another item\n  - A nested item\n\n```go\nfmt.Println(\"code remains monospace\")\n```"}]}},
          {id:"r",parentId:"a",type:"message",message:{role:"toolResult",toolName:"read",content:[{type:"text",text:"Read /tmp/example.go"}]}}
        ]}}),0)
      } else if (test.phase === 4) {
        var prose = test.find(rail, item => item.readOnly === true && typeof item.getText === "function" && item.getText(0,item.length).indexOf("A readable conversation") >= 0)
        test.check(prose && prose.font.family === "Geist" && prose.font.pixelSize === 17, "conversation font is not Geist 17px")
        test.check(prose.selectByMouse && !prose.activeFocusOnPress, "selection or focus behavior changed")
        var line1 = prose.positionToRectangle(0), line2 = line1
        for (var pos=1;pos<test.paragraph.length;pos++) {
          line2 = prose.positionToRectangle(pos)
          if (line2.y > line1.y) break
        }
        test.check(Math.abs(line2.y - line1.y - 26) < 1, "body leading is not 26px: " + JSON.stringify(line1) + " / " + JSON.stringify(line2))
        var plain=prose.getText(0,prose.length)
        var paragraphEnd=prose.positionToRectangle(test.paragraph.length-1)
        var secondParagraph=prose.positionToRectangle(plain.indexOf("Clear emphasis."))
        test.check(Math.abs(secondParagraph.y-paragraphEnd.y-52)<1,"paragraph rhythm is not 26px leading plus 26px gap")
        var firstListPos=plain.indexOf("A compact list"), firstList=prose.positionToRectangle(firstListPos)
        var continuation=firstList
        for (var lp=firstListPos+1;lp<plain.indexOf("Another item");lp++) {
          continuation=prose.positionToRectangle(lp)
          if (continuation.y>firstList.y) break
        }
        test.check(Math.abs(firstList.x-secondParagraph.x-26)<1,"list indentation is not 26px")
        test.check(Math.abs(continuation.x-firstList.x)<1,"wrapped list text lost its hanging indent")
        var nested=prose.positionToRectangle(plain.indexOf("A nested item"))
        test.check(Math.abs(nested.x-firstList.x-26)<1,"nested list indentation is not another 26px")
        prose.select(2,10)
        var selected = prose.selectedText
        ProseStyle.apply(prose.textDocument)
        test.check(prose.selectedText === selected, "formatting reset text selection")
        var linkPos = prose.getText(0,prose.length).indexOf("https://example.com"), linkRect = prose.positionToRectangle(linkPos)
        var href = prose.linkAt(linkRect.x + 2, linkRect.y + linkRect.height / 2)
        test.check(linkPos >= 0 && href === "https://example.com", "Markdown link formatting was lost: " + href + " " + JSON.stringify(linkRect) + " " + prose.getText(0,prose.length))
        var code = test.find(rail, item => item.text === 'fmt.Println("code remains monospace")')
        test.check(code && code.font.pixelSize === 16 && code.font.family !== "Geist", "code typography changed")
        var rows = rail.feedGeom()
        for (var i=1;i<rows.length;i++) test.check(rows[i].y >= rows[i-1].y+rows[i-1].h-1, "typography overlapped feed rows")
        console.log("PASS: Geist17 prose, 26px leading/paragraph gap/list indent, hanging and nested lists, selection/links preserved, monospace16 code, and non-overlapping rows")
        Qt.quit()
      }
      test.phase++
    }
  }
}
