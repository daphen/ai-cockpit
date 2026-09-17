import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "."
ShellRoot {
  id: test
  property int phase: 0
  property var sent: []
  property int serial: 0
  property int railWidth: 720
  property bool grewSmoothly: false
  property bool shrankSmoothly: false
  property real previousAttachmentHeight: 0
  Timer {
    interval: 16; repeat: true; running: true
    onTriggered: {
      var area = test.find(rail, "composerAttachments")
      if (!area) return
      var h = area.height
      if (h > 0 && h < 37) {
        if (h > test.previousAttachmentHeight) test.grewSmoothly = true
        if (h < test.previousAttachmentHeight) test.shrankSmoothly = true
      }
      test.previousAttachmentHeight = h
    }
  }
  property string selectedCode: "const text = `literal`;\n```\n  unsaved();"
  SocketServer { active: true; path: Quickshell.env("HOME") + "/agentd-personal.sock"; handler: Socket {} }
  AgentdState {
    id: state
    configuredSockPaths: [Quickshell.env("HOME") + "/agentd-personal.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { test.sent = test.sent.concat([message]); return true }
  }
  FileView { id: fixture; blockWrites: true }
  FileView { id: menuCalls; path: Quickshell.env("HOME") + "/menu-call"; blockAllReads: true; printErrors: false }
  FileView { id: submitted; path: Quickshell.env("HOME") + "/plan-submit-result"; blockAllReads: true; printErrors: false }
  Process {
    running: true; stdinEnabled: true
    command: ["nvim", "--headless", "-u", "NONE", "--listen", Quickshell.env("HOME") + "/nvim.sock", "--cmd",
      'lua package.preload["plan-nvim"]=function() return {menu=function(i,p) vim.fn.writefile({vim.json.encode({choice=i,path=p})},os.getenv("HOME").."/menu-call") end,submit_compose=function(p) vim.fn.writefile(vim.fn.readfile(p),os.getenv("HOME").."/plan-submit-result"); return "sent" end} end']
  }
  FloatingWindow {
    id: window
    property string pane: "rail"
    onPaneChanged: { if (pane === "nvim") editor.forceActiveFocus(); else rail.forceActiveFocus() }
    visible: true; implicitWidth: test.railWidth; implicitHeight: 800
    Item {
      id: editor
      onActiveFocusChanged: if (activeFocus) window.pane = "nvim"
      Keys.onPressed: event => { if (event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier)) { window.pane = "rail"; event.accepted = true } }
    }
    Rail {
      id: rail; anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
      width: test.railWidth; agentd: state; scopeMode: "personal"; instanceName: "code-context-test"; nvimSock: Quickshell.env("HOME") + "/nvim.sock"
      focused: window.pane === "rail"
      onFocusNvim: window.pane = "nvim"
      onRequestFocus: window.pane = "rail"
      onActiveFocusChanged: if (activeFocus) window.pane = "rail"
      TestEvent { id: keys }
    }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function find(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) { var hit = find(child,name); if (hit) return hit }
    return null
  }
  function context(data) {
    serial++
    fixture.path = Quickshell.env("HOME") + "/context-" + serial + ".json"
    fixture.setText(JSON.stringify(Object.assign({id:String(serial),session:"target",mode:"personal"},data)))
    return rail.receiveEditorContext(fixture.path)
  }
  function attach() { return context({kind:"code",path:"/repo/src/code.ts",l1:4,l2:7,lang:"typescript",text:selectedCode}) }
  function press(key, modifiers) { keys.keyClick(key, modifiers || Qt.NoModifier, 0) }
  Timer {
    interval: 150; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        if (!state.connected) return
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"target",name:"target",cwd:"/tmp",status:"idle"},{id:"other",name:"other",cwd:"/tmp",status:"idle"}]}),0)
      } else if (test.phase === 1) {
        rail.jumpToSession("target"); rail.prefillComposer("Explain this")
        test.sent = []
        test.check(test.attach() === "accepted", "code handoff refused")
      } else if (test.phase === 2) {
        test.check(rail.composerText === "Explain this" && test.sent.length === 0, "attachment changed or sent the draft")
        test.check(test.find(rail,"codeAttachment-0") !== null, "code tag missing")
        rail.jumpToSession("other")
        test.check(rail.codeAttachments.length === 0, "attachment leaked to another session")
        test.check(test.attach() !== "accepted", "stale sender attached to another session")
        rail.jumpToSession("target")
        test.check(rail.codeAttachments.length === 1, "returning lost the attachment")
        rail.removeCode(0)
        test.check(rail.attachRefs("question").indexOf(test.selectedCode) < 0, "removed attachment remained in payload")
        test.attach(); rail.prefillComposer("Explain this"); rail.enterInsert()
        test.press(Qt.Key_Return)
      } else if (test.phase === 3) {
        var prompt = test.sent.filter(m => m.type === "prompt").pop()
        test.check(prompt && prompt.message.indexOf(test.selectedCode) >= 0 && prompt.message.indexOf("````typescript") >= 0, "send lost exact code or fenced it unsafely: " + JSON.stringify(test.sent))
        test.check(rail.codeAttachments.length === 0, "sent attachment remained pending")
        state.onLine(JSON.stringify({type:"agent_end",session:"target"}),0)
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"target",name:"target",cwd:"/tmp",status:"streaming"},{id:"other",name:"other",cwd:"/tmp",status:"idle"}]}),0)
        test.attach(); rail.prefillComposer("Do this after"); rail.enterInsert()
        test.press(Qt.Key_Return, Qt.ControlModifier)
      } else if (test.phase === 4) {
        test.check(state.queuedFirst("target").indexOf(test.selectedCode) >= 0, "queue lost code context")
        var accepted = test.context({kind:"code",path:"/notes/plan.md",l1:1,l2:2,text:"- decision",fromPlan:true})
        test.check(rail.attachRefs("why").indexOf("do not edit the plan") >= 0, "plan-selection safeguard lost: " + accepted + " " + JSON.stringify(rail.codeAttachments))
        rail.clearCode()
        test.press(Qt.Key_P, Qt.ControlModifier)
        test.context({kind:"menu",path:"/notes/plan.md",title:"Plan actions",labels:["Open plan","Implement (finalize first)"]})
      } else if (test.phase === 5) {
        menuCalls.reload()
        test.check(menuCalls.text().length > 0, "rail Ctrl+P did not call the bound Neovim plan menu")
        test.check(test.find(rail,"planActionMenu").visible && rail.planMenu.labels.length === 2, "plan menu not shown in rail")
        test.press(Qt.Key_Escape)
        test.check(rail.planMenu === null, "Escape did not dismiss plan menu")
        test.context({kind:"menu",path:"/notes/plan.md",title:"Plan actions",labels:["Open plan"]})
        test.press(Qt.Key_Return)
        rail.prefillComposer("Existing question")
        test.context({kind:"compose",title:"amend plan"})
      } else if (test.phase === 6) {
        menuCalls.reload()
        test.check(JSON.parse(menuCalls.text()).choice === 1 && JSON.parse(menuCalls.text()).path === "/notes/plan.md", "menu choice did not reach the original plan controller")
        test.check(rail.planDraft && rail.composerText === "Existing question", "plan draft overwrote text or failed to attach")
        test.check(test.context({kind:"compose",title:"other"}) !== "accepted", "new plan action replaced a pending draft")
        rail.enterInsert(); test.press(Qt.Key_Return)
      } else if (test.phase === 7) {
        submitted.reload()
        test.check(rail.planDraft === null && rail.composerText === "", "confirmed plan submission did not clear its draft")
        test.check(JSON.parse(submitted.text()).text === "Existing question", "plan submit did not preserve the user's text")
        rail.prefillComposer("keep draft")
        test.press(Qt.Key_H, Qt.ControlModifier)
        test.check(window.pane === "nvim", "Ctrl+H did not leave the composer")
      } else if (test.phase === 8) {
        test.check(editor.activeFocus, "editor did not receive focus")
        test.press(Qt.Key_L, Qt.ControlModifier)
      } else if (test.phase === 9) {
        test.check(window.pane === "rail" && rail.insert, "Ctrl+L did not restore composer mode")
        test.press(Qt.Key_X)
        test.check(rail.composerText === "keep draftx", "returning to the rail stole focus from the input")
        test.press(Qt.Key_H, Qt.ControlModifier)
        test.check(window.pane === "nvim", "second Ctrl+H was trapped in the input")
        test.railWidth = 320
        test.context({kind:"code",path:"/repo/code-context.qml",l1:52,l2:57,text:"selection"})
        test.context({kind:"code",path:"/repo/a-very-long-filename-that-must-fit.qml",l1:1,l2:2,text:"other selection"})
      } else if (test.phase === 10) {
        var area = test.find(rail,"composerAttachments")
        if (area.height < 70) return
        test.check(area.height >= 70, "wrapped badges did not grow the attachment area: " + area.width + "×" + area.height + " count " + rail.codeAttachments.length)
        test.check(area.width <= rail.width - 56 && test.find(rail,"codeAttachment-1").width <= area.width, "long filename escaped the composer")
        var preview = Quickshell.env("CODE_CONTEXT_PREVIEW")
        if (preview) rail.grabToImage(result => result.saveToFile(preview))
      } else if (test.phase === 11) {
        var button = test.find(test.find(rail,"codeAttachment-0"),"removeCodeAttachment")
        keys.mouseMove(button,14,14,0,Qt.NoButton,Qt.NoModifier)
        keys.mouseClick(button,14,14,Qt.LeftButton,Qt.NoModifier,0)
        test.check(rail.codeAttachments.length === 1, "badge close button did not remove its attachment")
        rail.clearCode()
      } else if (test.phase === 12) {
        if (test.find(rail,"composerAttachments").height >= 1) return
        test.check(test.find(rail,"composerAttachments").height < 1, "empty attachments left a layout gap")
        test.check(test.grewSmoothly && test.shrankSmoothly, "attachment height jumped instead of transitioning both ways")
        test.attach(); rail.scopeMode = "work"
        test.check(rail.codeAttachments.length === 0 && test.attach() !== "accepted", "attachment leaked across scopes")
        console.log("PASS: code badges, animated height/wrapping, mouse removal, payloads, draft isolation, plan menu and focus round-trips")
        Qt.quit()
      }
      test.phase++
    }
  }
}
