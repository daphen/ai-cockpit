import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property string copiedCommand: ""
  FontMetrics { id: activityMetrics }
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
  function click(item) { check(!!item, "click target missing at phase " + phase); input.mouseClick(item, 5, item.height/2, Qt.LeftButton, Qt.NoModifier, 0) }
  function event(message) { state.onLine(JSON.stringify(message),0) }
  function history() {
    event({type:"response",command:"get_entries",session:"worker",data:{leafId:"a",entries:[
      {type:"message",id:"u",parentId:null,message:{role:"user",content:[{type:"text",text:"⇄ css-map (user-approved)\n"+report}]}},
      {type:"message",id:"a",parentId:"u",message:{role:"assistant",model:"gpt-6.1-sol",content:[
        {type:"thinking",thinking:"Investigating build graph\nLonger reasoning."},
        {type:"toolCall",id:"read",name:"read",arguments:{path:"package.json"}},
        {type:"toolCall",id:"bash",name:"bash",arguments:{command:"git diff --check"}},
        {type:"toolCall",id:"bash-multi",name:"bash",arguments:{command:"python3 - <<'PY'\nprint('fixture')\nPY"}},
        {type:"toolCall",id:"write",name:"write",arguments:{path:"/tmp/" + "long-file-name-".repeat(15) + ".ts",content:"export const ready = true"}},
        {type:"text",text:"The CSS rule is missing; the fix is not verified. I'll inspect `img729.png`; `npm run dev` is a command."},
        {type:"text",text:"A second consecutive agent reply."}
      ]}}
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
        var sender = test.label("From css-map (user-approved)")
        test.check(sender, "live handoff mislabeled")
        test.check(test.find(sender.parent, item => item.name === "sparkle-3"), "handoff lacks agent icon")
        var handoffFace = test.find(sender.parent.parent.parent, item => item.faceTop !== undefined)
        test.check(handoffFace && !handoffFace.elevated && Qt.colorEqual(handoffFace.faceTop, handoffFace.faceBottom), "handoff card is not flat")
        test.check(!test.label("You"), "handoff attributed to human")
        var preview = test.find(rail, item => item.text && item.text.indexOf("Finding: candidate CSS") === 0)
        test.check(preview && preview.maximumLineCount === 3 && preview.truncated, "missing bounded report preview")
        test.click(test.label("Show full message"))
      } else if (test.phase === 3) {
        test.check(test.label("Hide full message"), "message disclosure did not open")
        test.check(test.find(rail, item => item.text && item.text.indexOf("END OF REPORT") >= 0 && item.maximumLineCount !== 3), "full report unavailable")
        test.click(test.label("Hide full message"))
        test.history()
      } else if (test.phase === 5) {
        test.check(test.label("From css-map (user-approved)"), "history handoff lost its sender")
        test.check(!test.label("Investigating build graph"), "reasoning still visible by default")
        test.check(test.find(rail, item => item.text && item.text.indexOf("A second consecutive agent reply.") >= 0), "consecutive reply missing")
        var readActivity = test.label("Read (1): package.json")
        test.check(readActivity && test.label("Commands (2, latest 2)") && test.label("git diff --check"), "grouped activities are hidden by default")
        var command = test.label("python3 - <<'PY'")
        test.check(command && command.wrapMode === Text.WrapAnywhere && command.parent.radius === 6
                   && command.parent.color.a > 0 && command.width < command.parent.width, "command lacks its own wrapping background")
        test.check(test.find(command.parent, item => item.name === "clipboard"), "command copy icon missing")
        var readIcon = test.find(readActivity.parent, item => item.name === "book-open")
        test.check(readIcon, "read summary icon missing")
        activityMetrics.font = readActivity.font
        test.check(Math.abs(readIcon.y + readIcon.height / 2 - (readActivity.y + readActivity.baselineOffset - activityMetrics.capitalHeight / 2)) < 1,
                   "activity icon is not centred on the first line of text")
        test.click(command)
        test.check(test.copiedCommand === "python3 - <<'PY'\nprint('fixture')\nPY", "command card copied only the preview instead of the full multiline command")
        var summary = test.find(rail, item => item.text && item.text.indexOf("Edited: long-file-name-") === 0)
        test.check(summary && summary.height > 20 && summary.width <= summary.parent.width, "long activity summary does not wrap within the rail")
        test.check(readActivity.wrapMode === Text.Wrap && readActivity.elide === Text.ElideNone, "activity summary truncates useful text")
        var selected = test.find(rail, item => item.cursor === true && item.turn && item.turn.kind === "turn")
        var selectedCard = selected && test.find(selected, item => item.radius === 18 && item.border && item.border.width === 1)
        var selectedContent = selectedCard && selectedCard.children.find(item => item.spacing === 10)
        test.check(selectedCard && selectedCard.border.color.a > 0 && selectedContent && selectedContent.y === 14
                   && Math.abs(selectedCard.height - selectedContent.height - 28) < 1,
                   "selected article must have a purple outline and equal top/bottom padding")
        test.check(test.countLabels(rail, "Sol") === 0, "agent replies still show a model header")
        test.check(!test.find(rail, item => item.name === "sparkle-3" && item.parent.visible && !test.find(item.parent, child => child.text && child.text.indexOf("From ") === 0)), "agent replies still show a sparkle icon")
        test.check(test.find(rail, item => item.text === "The "), "answer hidden with details")
        var tagText = test.label("img729.png")
        var codeText = test.label("npm run dev")
        test.check(tagText && codeText, "inline file and command tags missing")
        test.check(Math.abs(tagText.mapToItem(rail, 0, 0).y - codeText.mapToItem(rail, 0, 0).y) < 3,
                   "inline tags broke the sentence onto another line")
        test.click(test.find(rail, item => item.text && item.text.indexOf("DETAILS") === 0))
      } else if (test.phase === 6) {
        var thought = test.label("Investigating build graph")
        test.check(thought, "details cannot reveal reasoning without Bash calls")
        var answer = test.find(rail, item => item.text === "The ")
        test.check(answer && answer.mapToItem(rail,0,0).y < thought.mapToItem(rail,0,0).y, "reasoning precedes answer")
        rail.cur = rail.rSize + 1; rail.exitInsert(); rail.forceActiveFocus()
        input.keyClick(Qt.Key_Return,Qt.ControlModifier,0)
      } else if (test.phase === 7) {
        test.check(!test.label("Investigating build graph"), "Ctrl+Enter failed to close details")
        var selection = test.find(rail, item => item.text === "The ")
        while (selection && !(selection.radius === 18 && selection.color !== undefined)) selection = selection.parent
        test.check(selection && selection.color.a > 0 && selection.border.width === 1 && selection.border.color.a > 0,
                   "agent selection needs a full background highlight and purple outline")
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
        var reportCard = test.label("From css-map (user-approved)").parent.parent.parent
        var available = reportCard.parent.width - 2 * reportCard.x
        test.check(Math.abs(reportCard.width / available - 0.9) < 0.01 && Math.abs(humanCard.width / available - 0.9) < 0.01, "human and handoff cards are not 90% width")
        test.check(Math.abs(humanCard.x + humanCard.width + reportCard.x - humanCard.parent.width) < 1, "human/handoff alignment is not right/left")
        state.sendPrompt("history1", "Accepted once")
        test.event({type:"prompt_accepted",session:"history1",message:"Accepted once"})
        test.check(state.feedFor("history1").filter(item => item.kind === "user" && item.text === "Accepted once").length === 1,
                   "acceptance receipt duplicated the optimistic user card")
        test.event({type:"message_start",session:"history1",message:{role:"assistant"}})
        test.event({type:"message_update",session:"history1",assistantMessageEvent:{type:"text_delta",delta:"A growing, wrapping reply. ".repeat(80)}})
      } else if (test.phase === 10) {
        var geometry = rail.feedGeom()
        for (var g = 1; g < geometry.length; g++) {
          if (geometry[g].i === geometry[g - 1].i + 1)
            test.check(geometry[g].y >= geometry[g - 1].y + geometry[g - 1].h, "growing message overlaps the next card")
        }
        console.log("PASS: message styles, equal selection padding, wrapping activity, single acceptance echo, and non-overlapping growing rows")
        Qt.quit()
      }
      test.phase++
    }
  }
}
