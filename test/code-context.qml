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
    visible: true; implicitWidth: 720; implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "code-context-test"; nvimSock: Quickshell.env("HOME") + "/nvim.sock"; focused: true; TestEvent { id: keys } }
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
    interval: 250; repeat: true; running: true
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
        test.attach(); rail.scopeMode = "work"
        test.check(rail.codeAttachments.length === 0 && test.attach() !== "accepted", "attachment leaked across scopes")
        console.log("PASS: code handoff/tag/removal, exact send and queue payloads, draft isolation, plan menu and safeguards")
        Qt.quit()
      }
      test.phase++
    }
  }
}
