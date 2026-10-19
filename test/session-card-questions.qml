import QtQuick
import QtTest
import Quickshell
import QsLib
import "."

ShellRoot {
  id: test
  property int phase: 0
  property var sent: []
  property bool online: true
  property string opened: ""
  property int sentBefore: 0
  property real meshBefore: 0
  readonly property string questionText: "The pushed PR still describes the superseded two-row UI and lists validation at an older commit. I prepared a body describing the final compact + New menu, the three-file feature scope, and the remaining manual checks without a CI list.\n\nMay I run exactly:\ngh pr edit 125061 --body-file .devenv/state/verification/every-3789-pr-body.scratch.md\n\nThis changes the PR description only; it does not mark the PR ready, approve visual differences, or merge." + "\n\nBackground: ".repeat(1) + "The earlier body was written before the compact layout landed. ".repeat(8)
  AgentdState {
    id: state
    sockPaths: [Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-work.sock"]
    selectedSession: "orchestrator"
    function send(message) { if (!test.online) return false; test.sent = test.sent.concat([message]); return true }
  }
  FloatingWindow {
    id: window
    visible: true; implicitWidth: 900; implicitHeight: 1400
    Dashboard {
      id: dash
      anchors.fill: parent
      model: ({kind:"home", scope:"lovable"})
      sessions: state.sessions.map(s => Object.assign({}, s, {offline:false, status:s.name === "helper" ? "streaming" : "idle"}))
      askFor: sid => { state.askGen; return state.askFor(sid) }
      answerSendingFor: sid => !!state._answerIntents[sid]
      onAnswerRequested: (sid, payload) => state.answerAsk(sid, payload)
      onPromptRequested: (sid, text) => state.isBusy(sid) ? state.steer(sid, text) : state.sendPrompt(sid, text)
      onSessionRequested: sid => test.opened = sid
      tickets: [{id:"EVERY-42",title:"Ticket with an approval"}, {id:"EVERY-43",title:"Other ticket"}]
    }
    TextInput { id: composer; width: 12; height: 12; anchors.right: parent.right }
  }
  TestEvent { id: input }
  function receive(message) { state.onLine(JSON.stringify(message), 0) }
  function check(value, message) { if (!value) throw new Error(message) }
  function find(item, name) {
    if (typeof name === "function" ? name(item) : item.objectName === name) return item
    for (var child of item.children || []) { var found = find(child, name); if (found) return found }
    return null
  }
  function ask(method) { receive({type:"extension_ui_request",session:"every-42",method:method,id:"ask-"+phase,title:"Approve the exact change?",message:test.questionText,options:["First", "Second"]}) }
  Timer {
    interval: 100; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        test.receive({type:"roster",sessions:[
          {name:"every-42",profile:"lovable-worker",cwd:"/vm/42",status:"idle"},
          {name:"every-43",profile:"lovable-worker",cwd:"/vm/43",status:"idle"},
          {name:"watch-pr-42",profile:"lovable-watcher",parent:"every-42",cwd:"/vm/42",status:"idle"},
          {name:"helper",profile:"lovable-worker",parent:"every-42",cwd:"/vm/42",status:"streaming"}
        ]})
        test.ask("confirm")
      } else if (test.phase === 1) {
        test.check(dash.workers.length === 2 && !test.find(dash,"sessionCard:watch-pr-42") && !test.find(dash,"sessionCard:helper"), "watcher or child became a card")
        var card = test.find(dash,"sessionCard:every-42")
        var question = test.find(card,"ticketQuestion"), badge = test.find(card,"sessionActivityBadge")
        var indicators = test.find(card,"subagentIndicators")
        test.check(question.visible && question.height > 0 && card.ask.message === test.questionText, "question was not rendered inline")
        test.check(Math.abs(indicators.y + 26 - badge.y - badge.height) < 0.01, "subagent indicators are not aligned with the activity badge")
        test.check(test.find(card,"subagent:watch-pr-42") && test.find(card,"subagent:helper"), "child indicators missing")
        var body = test.find(card,"questionBody")
        test.check(body.text === test.questionText && !body.truncated && body.wrapMode === Text.Wrap && body.lineHeight === 1.25, "question lost content or readable wrapping")
        var yes = test.find(card,"answerYes"), open = test.find(card,"openSession"), expand = test.find(card,"expandSession")
        test.check(yes.visible && yes.height === 28 && test.find(card,"answerNo").visible && !open.visible && !expand.visible && Math.abs(yes.mapToItem(card,0,0).y + 28 + 16 - card.height) < 1, "Yes/No did not replace the corner buttons")
        test.check(card.height === test.find(dash,"sessionCard:every-43").height, "question changed the card height")
        test.check(question.height < card.height && test.find(card,"collapsedLayer").layer.enabled && !test.find(card,"collapsedLayer").enabled, "card content was not veiled behind the question")
        var preview = Quickshell.env("COCKPIT_CARD_PREVIEW")
        if (preview) card.grabToImage(result => result.saveToFile(preview))
        composer.forceActiveFocus()
        input.mouseMove(card,20,20,0,Qt.NoButton,Qt.NoModifier)
      } else if (test.phase === 2) {
        test.check(dash.activeFocus, "hover did not focus the confirmation card")
        var asking = test.find(dash,"sessionCard:every-42"), scroll = test.find(asking,"questionScroll")
        dash.cursor = dash.selectable.indexOf("session:every-42")
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        test.check(!asking.expanded && dash.focusedQuestion === "every-42", "Enter expanded a question card instead of focusing the question")
        input.keyClick(Qt.Key_J,Qt.NoModifier,0)
        test.check(dash.currentAction === "session:every-42" && scroll.contentHeight > scroll.height + 60 && scroll.contentY === 60, "j did not scroll the question")
        for (var i = 0; i < 40; i++) input.keyClick(Qt.Key_J,Qt.NoModifier,0)
        test.check(scroll.contentY === Math.max(0, scroll.contentHeight - scroll.height), "question scroll overshot")
        input.keyClick(Qt.Key_Escape,Qt.NoModifier,0)
        test.check(dash.focusedQuestion === "" && !asking.expanded, "Esc did not release the question")
        input.keyClick(Qt.Key_Y,Qt.NoModifier,0)
        test.check(test.sent.length === 1 && test.sent[0].session === "every-42" && test.sent[0].response.confirmed === true, "hover Y answered the wrong session")
        test.check(state.askFor("every-42") && !test.find(dash,"answerYes").enabled, "question disappeared or allows duplicate sends before acknowledgment")
        input.keyClick(Qt.Key_N,Qt.NoModifier,0)
        test.check(test.sent.length === 1, "duplicate answer escaped the existing in-flight guard")
        test.receive({type:"ask_answered",session:"every-42"})
      } else if (test.phase === 3) {
        test.check(!test.find(dash,"sessionCard:every-42").asking && !test.find(test.find(dash,"sessionCard:every-42"),"ticketQuestion").enabled, "acknowledgment did not hide the question")
        test.ask("confirm")
      } else if (test.phase === 4) {
        var no = test.find(dash,"answerNo")
        input.mouseClick(no,10,10,Qt.LeftButton,Qt.NoModifier,0)
        test.check(test.sent.length === 2 && test.sent[1].response.confirmed === false, "mouse No failed")
        test.receive({type:"error",session:"every-42",error:"Rejected"})
      } else if (test.phase === 5) {
        test.check(state.askFor("every-42") && test.find(dash,"answerYes").enabled, "rejection lost the question or prevented retry")
        input.mouseMove(dash,2,2,0,Qt.NoButton,Qt.NoModifier)
        dash.cursor = dash.selectable.indexOf("session:every-42"); dash.forceActiveFocus()
        input.keyClick(Qt.Key_Y,Qt.NoModifier,0)
        test.check(test.sent.length === 3 && test.sent[2].session === "every-42" && test.sent[2].response.confirmed === true, "Y did not answer the keyboard-selected card")
        test.receive({type:"ask_answered",session:"every-42"})
        test.ask("select")
      } else if (test.phase === 6) {
        input.mouseClick(test.find(dash,"answerOption"),10,10,Qt.LeftButton,Qt.NoModifier,0)
        test.check(test.sent[test.sent.length - 1].response.value === "First", "choice response changed the existing payload")
        test.receive({type:"ask_answered",session:"every-42"})
        test.ask("input")
      } else if (test.phase === 7) {
        input.mouseClick(test.find(dash,"answerOption"),10,10,Qt.LeftButton,Qt.NoModifier,0)
        test.check(test.opened === "every-42", "text question did not open the existing session answer UI")
        dash.ticketStates = {"every-42":{label:"CI failing",tone:"error",chips:[{label:"PR #42",url:"https://example.test/pr"}],details:"Failed current-head checks",checkedAt:Date.now()}}
        test.receive({type:"ask_answered",session:"every-42"})
      } else if (test.phase === 8) {
        test.check(test.find(test.find(dash,"sessionCard:every-42"),"ticketStatusLabel").text === "CI failing", "ticket status is not visible")
        function lum(k) { return [k.r,k.g,k.b].map(x => x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4)).reduce((a,x,i) => a + x * [0.2126,0.7152,0.0722][i], 0) }
        Theme.mode = "light"
        var chip = test.find(test.find(dash,"sessionCard:every-42"), item => item.text === "PR #42"), a = lum(chip.color), b = lum(Theme.canvas)
        test.check((Math.max(a,b) + 0.05) / (Math.min(a,b) + 0.05) >= 4.5, "light-mode chip label is unreadable")
        Theme.mode = "dark"
        dash.ticketStates = {"every-42":{label:"Ready to merge",tone:"success",chips:[],details:"Old data",checkedAt:Date.now()-180000}}
      } else if (test.phase === 9) {
        test.check(test.find(test.find(dash,"sessionCard:every-42"),"ticketStatusLabel").text === "Status stale", "old readiness stayed green")
        var watcher = test.find(dash,"subagent:watch-pr-42")
        input.mouseMove(watcher,13,13,0,Qt.NoButton,Qt.NoModifier)
      } else if (test.phase === 10) {
        var tooltip = test.find(dash,"subagentTooltip")
        test.check(tooltip.shown && tooltip.visible && tooltip.radius === 10 && tooltip.height === 30 && tooltip.parent === dash, "watcher did not use the unclipped shared bar popup")
        test.check(tooltip.x >= 0 && tooltip.x + tooltip.width <= dash.width, "hover popup overflowed the viewport")
        var watcher = test.find(dash,"subagent:watch-pr-42")
        test.check(watcher.children.some(child => child.name === "binoculars"), "watcher lacks binoculars")
        dash.ticketStates = {"every-42":{label:"CI failing",tone:"error",chips:[],details:"Checked 09:40 UTC\nBranch: daphen/every-42-very-long-branch-name\nCI: Failed current-head checks\nHuman approval on PR head: not recorded",checkedAt:Date.now()}}
        dash.cursor = 1
        dash.forceActiveFocus()
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
      } else if (test.phase === 11) {
        var card = test.find(dash,"sessionCard:every-42"), details = test.find(card,"ticketStatusDetails")
        var layer = test.find(card,"expandedContent"), bar = test.find(card,"expandedScrollbar")
        test.check(details.visible && details.height > 100 && details.width <= card.width && layer.enabled, "expanded status facts are missing or overflow the card")
        if (layer.contentHeight > layer.height) {
          test.check(bar.visible, "overflow has no scrollbar")
          layer.contentY = layer.contentHeight - layer.height
          test.check(bar.y + bar.height <= layer.y + layer.height + 0.5, "scrollbar left the panel at the end")
        }
        dash.ticketStates = {"every-42":{label:"Merged",tone:"success",chips:[],details:"",action:"reap",checkedAt:Date.now()},
          "every-43":{label:"Local / PR head differ",tone:"accent",chips:[],details:"",action:"sync",localHead:"aaa111",prHead:"bbb222",branch:"daphen/every-43",pr:43,checkedAt:Date.now()}}
        dash.expandedSession = ""
      } else if (test.phase === 12) {
        test.meshBefore = test.find(test.find(dash,"sessionCard:every-43"),"sessionStatus").height
        var reap = test.find(test.find(dash,"sessionCard:every-42"),"ticketAction")
        test.check(reap.visible, "merged work ticket has no Reap button")
        test.sentBefore = test.sent.length
        input.mouseClick(reap,10,10,Qt.LeftButton,Qt.NoModifier,0)
        test.check(test.find(dash,"sessionCard:every-42").actionArmed && !test.find(dash,"sessionCard:every-42").actionMessage, "first click must only arm reap")
        var reapCard = test.find(dash,"sessionCard:every-42")
        reapCard.actionArmed = false
        dash.cursor = dash.selectable.indexOf("session:every-43"); dash.forceActiveFocus()
        input.keyClick(Qt.Key_D,Qt.NoModifier,0)
        test.check(!test.find(dash,"sessionCard:every-43").actionArmed, "d armed a non-reap card")
        dash.cursor = dash.selectable.indexOf("session:every-42")
        input.keyClick(Qt.Key_D,Qt.NoModifier,0)
        test.check(reapCard.actionArmed && !reapCard.actionMessage, "first d must only arm reap")
        input.keyClick(Qt.Key_D,Qt.NoModifier,0)
        var sync = test.find(test.find(dash,"sessionCard:every-43"),"ticketAction")
        input.mouseClick(sync,10,10,Qt.LeftButton,Qt.NoModifier,0)
        test.check(test.sent.length === test.sentBefore, "first sync click sent a prompt")
        input.mouseClick(sync,10,10,Qt.LeftButton,Qt.NoModifier,0)
        var prompt = JSON.stringify(test.sent[test.sent.length - 1])
        test.check(test.sent.length === test.sentBefore + 1 && prompt.indexOf("every-43") >= 0 && prompt.indexOf("aaa111") >= 0 && prompt.indexOf("bbb222") >= 0 && prompt.indexOf("without force") >= 0, "sync did not send the exact heads to the worker: " + prompt)
      } else if (test.phase === 15) {
        var synced = test.find(dash,"sessionCard:every-43")
        test.check(test.find(synced,"ticketActionStatus").visible && test.find(synced,"sessionStatus").height === test.meshBefore, "status line resized the preview: " + test.find(synced,"sessionStatus").height + " vs " + test.meshBefore)
        var card = test.find(dash,"sessionCard:every-42"), line = test.find(card,"ticketActionStatus").text
        test.check(line.indexOf("--unit cockpit-reap-every-42") >= 0 && /vm-wt --reap EVERY-42$/.test(line), "reap was not handed to a systemd unit that outlives Cockpit: " + line + " / " + card.actionMessage)
        test.check(card.reaping && card.ticket.label === "Reaping\u2026", "card does not say it is reaping: " + card.reapState + " " + card.ticket.label)
        test.check(test.find(card,"ticketActionStatus").visible, "reap progress line is hidden")
        test.check(!test.find(card,"ticketAction").enabled, "reap button stays clickable while reaping")
        dash.ticketStates = Object.assign({}, dash.ticketStates, {"every-43":{label:"Claude review needed",tone:"accent",chips:[],details:"Claude review on PR head: not recorded",action:"claude-review",pr:125061,repo:"lovablelabs/lovable",checkedAt:Date.now()}})
      } else if (test.phase === 16) {
        var review = test.find(test.find(dash,"sessionCard:every-43"),"ticketAction")
        test.check(review.visible, "Claude review needed has no request button")
        var reviewCard = test.find(dash,"sessionCard:every-43")
        function inside() { var at = review.mapToItem(reviewCard, 0, 0); return at.x >= 0 && at.x + review.width <= reviewCard.width }
        test.check(test.find(reviewCard,"expandSession").visible, "fixture lacks the Expand button real cards show")
        reviewCard.width = 300
        test.check(inside(), "Claude review button overflows the card: x=" + review.mapToItem(reviewCard,0,0).x)
        input.mouseClick(review,10,10,Qt.LeftButton,Qt.NoModifier,0)
        test.check(inside(), "armed Claude review button overflows the card: x=" + review.mapToItem(reviewCard,0,0).x)
        test.check(test.find(dash,"sessionCard:every-43").actionArmed && !test.find(dash,"sessionCard:every-43").claudeRequestedFor, "first click must only arm the Claude review request")
        input.mouseClick(review,10,10,Qt.LeftButton,Qt.NoModifier,0)
      } else if (test.phase === 18) {
        var asked = test.find(dash,"sessionCard:every-43")
        test.check(asked.actionMessage === "Claude review requested" && !asked.actionError, "Claude review was not requested with the exact comment: " + asked.actionMessage)
        test.check(!test.find(asked,"ticketAction").visible, "request button stays after the comment was posted")
        console.log("PASS: parent-only cards, watcher/helper indicators, shared bar hover popup and binoculars, inline confirmation, hover Y/N, mouse answers, ack/rejection, choices, text handoff, stale status, structured details, two-step reap (click and d), sync and Claude review request")
        Qt.quit()
      }
      test.phase++
    }
  }
}
