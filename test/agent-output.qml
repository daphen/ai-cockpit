import QtQuick
import QtTest
import QsLib
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property string copied: ""
  property string focusOwner: "rail"
  property var opened: ({})
  readonly property string output: "Finished\n/tmp/output.go:23\nline 3\nline 4\nline 5\nline 6\nEND OF OUTPUT"
  AgentdState { id: state; scope: "personal"; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    id: window
    visible: true; width: 850; height: 1500
    Rail {
      id: rail; width: test.phase >= 8 ? 360 : parent.width; height: parent.height; agentd: state; scopeMode: "personal"; instanceName: "agent-output-test"; focused: true
      function copyText(text) { test.copied = text }
      function openInNvim(path, cwd, line, column) { test.opened = {path:path,line:line}; rail.focusNvim() }
      onFocusNvim: test.focusOwner = "editor"
      onRequestFocus: test.focusOwner = "rail"
      TestEvent { id: input }
    }
  }
  TestCase { id: gui; when: false }
  function check(value, message) { if (!value) throw new Error(message) }
  function find(item, predicate) {
    if (!item || item.visible === false) return null
    if (predicate(item)) return item
    for (var child of item.children || []) { var found = find(child, predicate); if (found) return found }
    return null
  }
  function named(name) { return find(rail, item => item.objectName === name) }
  function label(text, root) { return find(root || rail, item => item.text === text) }
  function click(item) { check(!!item,"click target missing at " + phase); gui.wait(30); input.mouseClick(item,5,item.height/2,Qt.LeftButton,Qt.NoModifier,0) }
  function revealTools() {
    check(find(rail, item => String(item.objectName || "").indexOf("work-details:") === 0), "work disclosure missing at " + phase)
    var heading
    while ((heading = find(rail, item => String(item.objectName || "").indexOf("work-details:") === 0
                          && find(item, child => child.name === "chevron-right")))) click(heading)
  }
  function event(message) { state.onLine(JSON.stringify(Object.assign({session:"worker"},message)),0) }
  function result(id, tool, text, failed) {
    event({type:"tool_execution_end",toolCallId:id,toolName:tool,isError:failed,result:{content:[{type:"text",text:text}],details:tool === "bash" ? {exitCode:failed ? 1 : 0} : {}}})
  }
  function history() {
    var calls = [
      {type:"toolCall",id:"bash",name:"bash",arguments:{command:"bash fixture command"}},
      {type:"toolCall",id:"edit",name:"edit",arguments:{path:"/tmp/change.qml",edits:[{oldText:"old",newText:"new"}]}},
      {type:"toolCall",id:"edit2",name:"edit",arguments:{path:"/tmp/other.qml",edits:[{oldText:"old",newText:"new"}]}},
      {type:"toolCall",id:"edit3",name:"edit",arguments:{path:"/tmp/change.qml",edits:[{oldText:"old",newText:"new"}]}},
      {type:"toolCall",id:"mcp",name:"mcp",arguments:{server:"fixture",tool:"query",args:{query:"FULL ARGUMENT"}}},
      {type:"toolCall",id:"read",name:"read",arguments:{path:"/tmp/live.qml"}}
    ]
    var entries = [{type:"message",id:"a",parentId:null,message:{role:"assistant",stopReason:"length",content:calls.concat([{type:"text",text:"Code lives in the editor.\n```qml\nSOURCE_ONLY_NEOVIM\n```"}])}}], parent = "a"
    for (var call of calls) {
      var text = call.id === "bash" ? output : call.id === "edit" ? "Permission denied" : call.id === "mcp" ? "MCP structured result" : call.id === "read" ? "SOURCE_ONLY_NEOVIM" : "Saved"
      entries.push({type:"message",id:"r"+call.id,parentId:parent,message:{role:"toolResult",toolCallId:call.id,toolName:call.name,isError:call.id === "edit",content:[{type:"text",text:text}]}})
      parent = "r"+call.id
    }
    event({type:"response",command:"get_entries",data:{entries:entries,leafId:parent}})
  }
  Timer {
    interval: 260; repeat: true; running: true
    onTriggered: {
      if (phase === 0) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
        rail.jumpToSession("worker")
        event({type:"response",command:"get_entries",data:{entries:[]}})
        event({type:"tool_execution_start",toolCallId:"bash",toolName:"bash",args:{command:"bash fixture command"}})
        for (var item of [{id:"edit",path:"/tmp/change.qml"},{id:"edit2",path:"/tmp/other.qml"},{id:"edit3",path:"/tmp/change.qml"}])
          event({type:"tool_execution_start",toolCallId:item.id,toolName:"edit",args:{path:item.path,edits:[{oldText:"old",newText:"new"}]}})
        event({type:"tool_execution_start",toolCallId:"mcp",toolName:"mcp",args:{server:"fixture",tool:"query",args:{query:"FULL ARGUMENT"}}})
        event({type:"tool_execution_start",toolCallId:"read",toolName:"read",args:{path:"/tmp/live.qml"}})
        event({type:"tool_execution_update",toolCallId:"bash",partialResult:{content:[{type:"text",text:"alpha"}]}})
      } else if (phase === 1) {
        check(!named("tool-preview:bash") && !label("Copy output"),"compact rows still show output panels or button bars")
        revealTools()
        click(label("fixture command"))
      } else if (phase === 2) {
        check(named("tool-output:bash") && named("tool-output:bash").text === "alpha","live output inaccessible: " + JSON.stringify(rail.expandedGroups))
        event({type:"tool_execution_update",toolCallId:"bash",partialResult:{content:[{type:"text",text:"omega"}]}})
      } else if (phase === 3) {
        check(named("tool-output:bash").text === "omega","non-tail same-length progress stayed stale")
        result("bash","bash",output,false)
        result("edit","edit","Permission denied",true)
        result("edit2","edit","Saved",false)
        result("edit3","edit","Saved",false)
        result("mcp","mcp","\u001b[34mMCP structured result\u001b[0m",false)
        result("read","read","SOURCE_ONLY_NEOVIM",false)
        event({type:"response",command:"get_session_stats",success:true,data:{tokens:{total:999,input:800,output:199},cost:0.1}})
      } else if (phase === 4) {
        check(named("tool-output:bash").text === output,"final output lost its payload")
        var failure = named("tool-preview:edit")
        check(failure && failure.text === "Permission denied" && Qt.colorEqual(failure.color,Theme.red),"edit failure diagnostic hidden")
        var editColumn = failure.parent.parent.parent.parent
        check(editColumn.height - failure.parent.mapToItem(editColumn,0,failure.parent.height).y >= 12,"failed grouped edit lost bottom padding")
        var heading = label("File changes · 2 files"), plus = find(heading && heading.parent,item => item.name === "square-plus")
        check(!!heading,"adjacent edits or repeated paths were not grouped")
        check(plus && Math.abs(heading.x - plus.x - plus.width - 8) < 1,"group header has an oversized icon gutter")
        var table = heading.parent.parent.parent.parent
        function brightness(color) { return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722 }
        check(table.color.a === 1 && brightness(table.color) > brightness(rail.railGroundColor)
              && brightness(table.color) < brightness(rail.userCardBottom),"file table is not lighter than canvas and darker than user messages")
        var diff = find(heading.parent,item => String(item.text || "").startsWith("+"))
        check(diff && Math.abs(diff.mapToItem(rail,0,0).y - heading.mapToItem(rail,0,0).y) < 1,"group total diff is not inline with its title")
        check(!named("tool-preview:read") && !named("tool-output:read"),"read source shown inline")
        var frame = label("fixture command")
        while (frame && !(frame.radius === 18 && frame.border && frame.border.width === 1)) frame = frame.parent
        var shell = find(label("fixture command").parent,item => item.name === "keyboard")
        check(frame && Math.abs(shell.mapToItem(frame,0,0).x - 48) < 1,"tool rows lost their subordinate indentation")
        check(!find(rail,item => String(item.text || "").indexOf("999 tokens") >= 0),"session totals leaked into chat")
        click(label("Copy output",named("tool-output:bash").parent.parent.parent))
        check(copied === output,"copy output lost full log")
        click(label("Copy command",named("tool-output:bash").parent.parent.parent))
        check(copied === "bash fixture command","display cleanup changed the real command")
        click(label("change.qml"))
        check(opened.path === "/tmp/change.qml" && focusOwner === "editor","write row click did not open and focus Neovim")
        opened = {}; click(label("read live.qml"))
        check(!opened.path,"read row still opens a file")
        rail.exitInsert(); rail.forceActiveFocus()
        var other = label("other.qml")
        input.mouseMove(other,5,other.height/2,0,Qt.NoButton,Qt.NoModifier)
      } else if (phase === 5) {
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        check(opened.path === "/tmp/other.qml","hover + Enter did not open hovered write")
        history()
        state.steer("worker","Readable queued instruction")
        event({type:"queue_update",steering:["Readable queued instruction"],followUp:[]})
      } else if (phase === 6) {
        revealTools()
        check(named("tool-output:bash") && named("tool-output:bash").text === output,"refresh lost output or expansion")
        check(!find(rail,item => String(item.text || "").indexOf("SOURCE_ONLY_NEOVIM") >= 0),"rebuilt or fenced source shown inline")
        var repeats = 0
        function countQueued(item) {
          if (!item || item.visible === false) return
          if (String(item.text || "").indexOf("Readable queued instruction") >= 0) repeats++
          for (var child of item.children || []) countQueued(child)
        }
        countQueued(rail); check(repeats === 1,"steering message rendered " + repeats + " times")
        check(!named("tool-code-panel:queue"),"queue still contains an empty output box")
        var prose = find(rail,item => String(item.text || "").includes("Code lives in the editor."))
        var readIcon = find(label("read live.qml").parent,item => item.name === "file-content")
        check(prose && readIcon && Math.abs(readIcon.mapToItem(rail,0,0).x - prose.mapToItem(rail,0,0).x - 24) < 1,"tools are not indented beneath agent prose")
        rail.cur = rail.rSize; rail.exitInsert(); rail.forceActiveFocus()
        input.keyClick(Qt.Key_Return,Qt.ControlModifier,0)
      } else if (phase === 7) {
        check(named("tool-output:mcp") && named("tool-output:mcp").text === "MCP structured result","ANSI cleanup or Ctrl+Enter output failed")
        check(!named("tool-output:read"),"Ctrl+Enter exposed source code")
        var readRow = label("read live.qml").parent.parent
        check(!label("Copy output",readRow) && !label("Show details",readRow),"read acquired controls after expansion")
        var control = label("Hide details",named("tool-output:edit").parent.parent.parent)
        check(control && Qt.colorEqual(control.color,Theme.fg_muted),"failure painted its control red")
        var warnings = 0
        function count(item) {
          if (!item || item.visible === false) return
          if (String(item.text || "").indexOf("response hit its output cap") >= 0) warnings++
          for (var child of item.children || []) count(child)
        }
        count(rail); check(warnings === 1,"one cutoff rendered " + warnings + " warnings")
        event({type:"response",command:"get_entries",data:{entries:[]}})
        event({type:"tool_execution_start",toolCallId:"gh",toolName:"bash",args:{command:"gh api fixture/protection"}})
        result("gh","bash",'{"message":"Not Found","documentation_url":"https://example.com/docs","status":"404"}gh: Not Found (HTTP 404)\n\nCommand exited with code 1',true)
        event({type:"tool_execution_start",toolCallId:"grep",toolName:"bash",args:{command:"rg -n code fixture.qml"}})
        result("grep","bash","590: function activityRows(items) {\nSOURCE_ONLY_NEOVIM\nCommand exited with code 1",true)
        event({type:"tool_execution_start",toolCallId:"single",toolName:"edit",args:{path:"/tmp/single.qml",edits:[{oldText:"old",newText:"new"}]}})
        result("single","edit","edits[3] and edits[2] overlap in qs-shell/Rail.qml. Merge them into one edit or target disjoint regions.",true)
        event({type:"tool_execution_start",toolCallId:"linear",toolName:"mcp",args:{tool:"linear_list_projects"}})
        result("linear","mcp",'Error: {"error":"invalid_request","message":"The query is too complex.","status":400,"requestId":"hidden-request-id"}',true)
      } else if (phase === 8) {
        revealTools()
        var error = named("tool-preview:gh"), source = named("tool-preview:grep")
        check(error && error.text === "Not Found · HTTP 404 · Exit code 1","JSON API error was not formatted: " + (error && error.text) + " " + JSON.stringify(rail.expandedGroups))
        var linear = named("tool-preview:linear")
        check(linear && linear.text === "Invalid request\nThe query is too complex. · HTTP 400", "prefixed MCP JSON lacks a readable title and message")
        var overlap = named("tool-preview:single")
        check(error.wrapMode === Text.WordWrap && overlap && overlap.wrapMode === Text.WordWrap && overlap.lineCount > 1,"narrow error does not wrap at word boundaries: " + JSON.stringify({mode:error.wrapMode,overlapMode:overlap && overlap.wrapMode,lines:overlap && overlap.lineCount,width:overlap && overlap.width,text:overlap && overlap.text,windowWidth:window.width}))
        check(source && source.text === "Command failed · Exit code 1" && !find(rail,item => String(item.text || "").includes("SOURCE_ONLY_NEOVIM")),"failed source search dumped code")
        check(label("single.qml") && !find(rail,item => item.files && item.files.length === 1),"single-file change acquired a grouped card")
        var bubble = find(rail,item => item.radius === 18 && item.parent && item.parent.isUser === true)
        check(bubble && Math.abs(bubble.mapToItem(rail,bubble.width,0).x - error.parent.mapToItem(rail,error.parent.width,0).x) < 1,"error and user bubble outer gutters differ")
        check(error.x === 36 && error.y === 16,"error content does not align with its command label and vertical padding")
        var command = find(rail,item => String(item.text || "").startsWith("gh api fixture/protection"))
        var shell = find(command.parent,item => item.name === "keyboard")
        var metrics = Qt.createQmlObject('import QtQuick; FontMetrics {}',test)
        metrics.font = command.font
        var ink = metrics.tightBoundingRect(command.text)
        check(shell && Math.abs(shell.y + shell.height/2 - command.y - command.baselineOffset - ink.y - ink.height/2) < 1,"shell icon is not centered on rendered command")
        metrics.destroy()
        click(command)
      } else if (phase === 9) {
        var details = named("tool-details:gh")
        check(details && details.text.includes('\n  "message": "Not Found"') && details.wrapMode === TextEdit.WordWrap,"expanded error details are not formatted")
        console.log("PASS: live/final/history output, grouped versus single edits, inline totals and icon spacing, passive reads, source suppression, unique steers, JSON errors, word wrap, equal message gutters, centered shell glyph, copy and Neovim actions")
        Qt.quit()
      }
      phase++
    }
  }
}
