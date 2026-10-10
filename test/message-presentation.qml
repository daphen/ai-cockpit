import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property string copiedCommand: ""
  readonly property string report: "Finding: candidate CSS is missing. " + "Evidence from the served stylesheet. ".repeat(30) + "END OF REPORT"
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 1000
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "message-presentation-test"; focused: true
      onRequestFocus: forceActiveFocus()
      function copyText(text) { test.copiedCommand = text }
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
  function label(text) { return find(rail, item => item.text === text) }
  function countLabels(item, text) {
    if (!item || item.visible === false) return 0
    var count = item.text === text ? 1 : 0
    for (var child of item.children || []) count += countLabels(child, text)
    return count
  }
  function click(item) { check(!!item, "click target missing at phase " + phase); gui.wait(30); input.mouseClick(item, 5, item.height/2, Qt.LeftButton, Qt.NoModifier, 0) }
  function event(message) { state.onLine(JSON.stringify(message),0) }
  function history() {
    event({type:"response",command:"get_entries",session:"worker",data:{leafId:"result",entries:[
      {type:"message",id:"u",parentId:null,message:{role:"user",content:[{type:"text",text:"⇄ css-map (user-approved)\n"+report}]}},
      {type:"message",id:"a",parentId:"u",message:{role:"assistant",model:"gpt-6.1-sol",content:[
        {type:"thinking",thinking:"Investigating build graph\nLonger reasoning."},
        {type:"toolCall",id:"read",name:"read",arguments:{path:"package.json"}},
        {type:"toolCall",id:"bash",name:"bash",arguments:{command:"git diff --check"}},
        {type:"toolCall",id:"bash-multi",name:"bash",arguments:{command:"python3 - <<'PY'\nprint('fixture')\nPY"}},
        {type:"toolCall",id:"write",name:"write",arguments:{path:"/tmp/" + "long-file-name-".repeat(15) + ".ts",content:"export const ready = true"}},
        {type:"text",text:"The CSS rule is missing. I'll inspect `img729.png`; `npm run dev` is a command."},
        {type:"text",text:"A second consecutive agent reply."}
      ]}},
      {type:"message",id:"result",parentId:"a",message:{role:"toolResult",toolCallId:"bash",toolName:"bash",isError:true,content:[{type:"text",text:"Command failed in fixture"}]}}
    ]}})
  }
  Timer {
    interval: 200; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
      else if (test.phase === 1) {
        rail.jumpToSession("worker")
        test.event({type:"prompt_accepted",session:"worker",message:"⇄ css-map (user-approved)\n"+test.report})
      } else if (test.phase === 2) {
        var sender = test.label("From css-map")
        test.check(sender && !test.label("From css-map (user-approved)"), "live handoff leaks its permission marker")
        test.check(test.find(sender.parent, item => item.name === "sparkle-3"), "handoff lacks agent icon")
        var handoffFace = test.find(sender.parent.parent.parent, item => item.faceTop !== undefined)
        test.check(!handoffFace, "handoff still has a message-card surface")
        var note = sender.parent.parent.parent
        rail.exitInsert(); rail.cur = rail.rSize - 1
        input.mouseMove(note, 5, 5, 0, Qt.NoButton, Qt.NoModifier)
        test.check(note.border.width === 1 && note.border.color.a > 0 && note.color.a === 0, "handoff hover lacks an outline")
        input.mouseMove(rail, 1, rail.height - 1, 0, Qt.NoButton, Qt.NoModifier)
        rail.forceActiveFocus(); input.keyClick(Qt.Key_J,Qt.NoModifier,0)
        test.check(rail.cur === rail.rSize && note.border.width === 1 && note.border.color.a > 0, "keyboard navigation to handoff lacks an outline")
        test.check(!test.label("You"), "handoff attributed to human")
        var preview = test.find(rail, item => item.text && item.text.indexOf("Finding: candidate CSS") === 0)
        test.check(preview && preview.maximumLineCount === 2 && preview.truncated, "missing bounded report preview")
        var disclosure = test.label("Show full message")
        test.check(disclosure && disclosure.primary === false && disclosure.iconName === "chevron-right", "message disclosure is not the shared secondary button")
        test.click(disclosure)
      } else if (test.phase === 3) {
        test.check(test.label("Hide full message"), "message disclosure did not open")
        var expandedNote = test.label("From css-map").parent.parent.parent
        var expandedContent = expandedNote.children.find(item => item.spacing === 16)
        test.check(expandedNote.border.width === 1 && expandedContent && expandedContent.y === 16
                   && Math.abs(expandedNote.height - expandedContent.height - 32) < 1, "expanded handoff lacks its outline and reading padding")
        test.check(test.find(rail, item => item.text && item.text.indexOf("END OF REPORT") >= 0 && item.maximumLineCount !== 2), "full report unavailable")
        test.click(test.label("Hide full message"))
        test.check(test.label("Show full message"), "message disclosure toggled twice or did not close")
        test.history()
      } else if (test.phase === 5) {
        test.check(test.label("From css-map") && !test.label("From css-map (user-approved)"), "history handoff leaks its permission marker")
        test.check(!test.label("Investigating build graph"), "reasoning still visible by default")
        test.check(test.find(rail, item => item.text && item.text.indexOf("A second consecutive agent reply.") >= 0), "consecutive reply missing")
        var workDetails = test.find(rail, item => String(item.objectName || "").indexOf("work-details:") === 0)
        test.check(workDetails && !test.label("read package.json") && test.label("1 failed"), "completed tool activity is not compact with its failure count")
        test.click(workDetails)
        test.check(test.label("read package.json"), "work details did not reveal the read call")
        var handoffIcon = test.find(test.label("From css-map").parent, item => item.name === "sparkle-3")
        var readIcon = test.find(test.label("read package.json").parent, item => item.name === "file-content")
        test.check(Math.abs(readIcon.mapToItem(rail,0,0).x - handoffIcon.mapToItem(rail,0,0).x - 24) < 1,
                   "tools are not indented beneath the incoming-agent header")
        test.check(test.label("git diff --check  — failed"), "failed command hidden behind disclosure")
        test.check(test.find(rail, item => typeof item.text === "string" && item.text.indexOf("python3 - <<'PY'") === 0), "command call hidden behind disclosure")
        test.check(test.find(rail, item => typeof item.text === "string" && item.text.indexOf("long-file-name-") >= 0), "edited file hidden behind disclosure")
        test.check(!test.label("python3 - <<'PY'\nprint('fixture')\nPY"), "full command expanded by default")
        var selected = test.find(rail, item => item.cursor === true && item.turn && item.turn.kind === "turn")
        var selectedCard = selected && test.find(selected, item => item.radius === 18 && item.border && item.border.width === 1)
        var selectedContent = selectedCard && selectedCard.children.find(item => item.spacing === 16)
        test.check(selectedCard && selectedCard.border.color.a > 0 && selectedContent && selectedContent.y === 16
                   && selectedContent.anchors.leftMargin === 36 && selectedContent.anchors.rightMargin === 36
                   && Math.abs(test.label("The ").mapToItem(selectedCard,0,0).x - 24) < 1
                   && Math.abs(selectedCard.height - selectedContent.height - 32) < 1,
                   "selected article must have a purple outline and equal top/bottom padding")
        test.check(test.countLabels(rail, "Sol") === 0, "agent replies still show a model header")
        test.check(!test.find(rail, item => item.name === "sparkle-3" && item.parent.visible && !test.find(item.parent, child => child.text && child.text.indexOf("From ") === 0)), "agent replies still show a sparkle icon")
        test.check(test.find(rail, item => item.text === "The "), "answer hidden with details")
        var tagText = test.label("img729.png")
        var codeText = test.label("npm run dev")
        test.check(tagText && codeText, "inline file and command tags missing")
        test.check(Math.abs(tagText.mapToItem(rail, 0, 0).y - codeText.mapToItem(rail, 0, 0).y) < 3,
                   "inline tags broke the sentence onto another line")
        test.click(test.label("Reasoning"))
      } else if (test.phase === 6) {
        var thought = test.label("Investigating build graph")
        test.check(thought, "details cannot reveal reasoning without Bash calls")
        var commandRow = test.find(rail, item => typeof item.text === "string" && item.text.indexOf("python3 - <<'PY'") === 0)
        test.check(commandRow, "full command cannot be reached through Details")
        test.check(!test.label("python3 - <<'PY'\nprint('fixture')\nPY"), "desktop exposed multiline source code")
        test.click(commandRow)
        var answer = test.find(rail, item => item.text === "The ")
        test.check(answer && thought.mapToItem(rail,0,0).y < answer.mapToItem(rail,0,0).y, "answer moved above prior reasoning")
      } else if (test.phase === 7) {
        test.check(!test.label("python3 - <<'PY'\nprint('fixture')\nPY"), "desktop showed command source after copying")
        var commandRow = test.find(rail, item => typeof item.text === "string" && item.text.indexOf("python3 - <<'PY'") === 0)
        var scope = commandRow, copyCommand = null
        for (var up = 0; up < 5 && scope && !copyCommand; up++) { scope = scope.parent; copyCommand = test.find(scope, item => item.text === "Copy command") }
        test.check(copyCommand, "copy command unavailable: " + JSON.stringify(rail.expandedGroups) + " position " + JSON.stringify(commandRow.mapToItem(rail,0,0)))
        test.click(copyCommand)
        test.check(test.copiedCommand === "python3 - <<'PY'\nprint('fixture')\nPY", "command copy lost its multiline payload: " + JSON.stringify(test.copiedCommand))
        rail.cur = rail.rSize + 1; rail.exitInsert(); rail.forceActiveFocus()
        input.keyClick(Qt.Key_Return,Qt.ControlModifier,0)
      } else if (test.phase === 8) {
        test.check(!test.label("Investigating build graph"), "Ctrl+Enter failed to close details")
        test.check(!test.label("read package.json"), "Ctrl+Enter failed to collapse work details")
        var selection = test.find(rail, item => String(item.objectName || "").indexOf("work-details:") === 0)
        while (selection && !(selection.radius === 18 && selection.color !== undefined)) selection = selection.parent
        test.check(selection && selection.color.a === 0 && selection.border.width === 1 && selection.border.color.a > 0,
                   "agent selection needs a purple outline without a background fill")
        rail.cur = rail.rSize
        input.mouseMove(selection, 5, 5, 0, Qt.NoButton, Qt.NoModifier)
        test.check(selection.color.a === 0 && selection.border.width === 1 && selection.border.color.a > 0,
                   "article hover needs an outline without a background fill")
        test.event({type:"error",session:"worker",error:"Worker report was not delivered"})
      } else if (test.phase === 9) {
        test.check(test.label("Worker report was not delivered"), "delivery error hidden")
        test.event({type:"prompt_accepted",session:"worker",message:"A normal human message"})
      } else if (test.phase === 11) {
        var human = test.label("You")
        test.check(human, "human message attribution changed")
        test.check(test.find(human.parent, item => item.name === "paper-plane-2"), "human lacks prompt icon")
        var humanFace = test.find(human.parent.parent.parent, item => item.faceTop !== undefined)
        test.check(humanFace && humanFace.elevated, "human card lost its distinct surface")
        var composer = test.find(rail, item => item.objectName === "composerFrame")
        var composerFace = test.find(composer, item => item.faceTop !== undefined)
        var pane = test.find(rail, item => item.objectName === "chinContent").parent
        var paneFace = test.find(pane, item => item.faceTop !== undefined)
        test.check(composerFace && paneFace && Qt.colorEqual(composerFace.faceTop, humanFace.faceTop)
                   && Qt.colorEqual(composerFace.faceBottom, humanFace.faceBottom)
                   && Qt.colorEqual(paneFace.faceTop, humanFace.faceTop)
                   && Qt.colorEqual(paneFace.faceBottom, humanFace.faceBottom), "composer surfaces do not match human cards")
        var humanCard = human.parent.parent.parent
        var reportCard = test.label("From css-map").parent.parent.parent
        var available = reportCard.parent.width - 2 * (reportCard.x + 12)
        test.check(Math.abs(reportCard.width / (available + 24) - 1) < 0.01 && Math.abs(humanCard.width / available - 0.9) < 0.01, "human cards and inline handoffs lost their distinct widths")
        test.check(Math.abs(humanCard.x + humanCard.width + reportCard.x + 12 - humanCard.parent.width) < 1, "human/handoff alignment is not right/left")
        state.sendPrompt("history1", "Accepted once")
        test.event({type:"prompt_accepted",session:"history1",message:"Accepted once"})
        test.check(state.feedFor("history1").filter(item => item.kind === "user" && item.text === "Accepted once").length === 1,
                   "acceptance receipt duplicated the optimistic user card")
        test.event({type:"message_start",session:"worker",message:{role:"assistant"}})
        test.event({type:"message_update",session:"worker",assistantMessageEvent:{type:"text_delta",delta:"A growing, wrapping reply. ".repeat(80)}})
        test.event({type:"prompt_accepted",session:"worker",message:"Following card stays below the growing reply"})
        test.event({type:"prompt_accepted",session:"worker",message:"Second consecutive user card stays separate"})
        test.event({type:"prompt_accepted",session:"worker",message:"Keep the same scope",steered:true})
      } else if (test.phase === 13) {
        test.check(test.find(rail, item => item.text && item.text.indexOf("A growing, wrapping reply.") >= 0), "growing reply is not in the displayed session")
        test.check(test.find(rail, item => item.text && item.text.indexOf("Following card stays below") >= 0), "following card is not visible")
        test.check(test.find(rail, item => item.text && item.text.indexOf("Second consecutive user card") >= 0), "consecutive user card is not visible")
        var steering = test.label("steer")
        test.check(steering && test.find(steering.parent.parent, item => item.text === "You") && !test.label("Steering"), "steering is not attributed to You")
        var steeringCard = steering.parent.parent.parent.parent
        var steeringFace = test.find(steeringCard, item => item.faceTop !== undefined)
        test.check(steeringFace && steeringFace.elevated && Qt.colorEqual(steeringFace.faceTop, rail.userCardTop)
                   && Qt.colorEqual(steeringFace.faceBottom, rail.userCardBottom), "steering lost the normal user-card surface")
        var geometry = rail.feedGeom()
        for (var g = 1; g < geometry.length; g++) {
          if (geometry[g].i === geometry[g - 1].i + 1)
            test.check(geometry[g].y + 1 >= geometry[g - 1].y + geometry[g - 1].h, "growing message overlaps the next card")
        }
        test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"},{id:"reason-worker",name:"reason-worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("reason-worker")
        test.event({type:"response",command:"get_entries",session:"reason-worker",data:{leafId:"reason-only",entries:[{type:"message",id:"reason-only",parentId:null,message:{role:"assistant",content:[{type:"thinking",thinking:"Reasoning without tools remains accessible"}]}}]}})
      } else if (test.phase === 14) {
        var details = test.label("Reasoning")
        test.check(details && !test.label("Reasoning without tools remains accessible"), "reasoning-only activity lost its disclosure")
        test.click(details)
      } else if (test.phase === 15) {
        test.check(test.label("Reasoning without tools remains accessible"), "reasoning-only disclosure cannot expand")
        console.log("PASS: user-style steering, outlined handoffs, clean sender labels, inline tools, accessible reports/commands/reasoning, and non-overlapping growing rows")
        Qt.quit()
      }
      test.phase++
    }
  }
}
