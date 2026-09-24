import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
  id: test
  property int phase: 0
  readonly property bool deck: Quickshell.env("COCKPIT_DECK") === "1"
  readonly property bool narrow: deck || Quickshell.env("COCKPIT_NARROW_TEST") === "1"
  property var sent: []
  readonly property var answers: sent.filter(message => message.type === "answer")
  SocketServer { active: true; path: Quickshell.env("HOME") + "/agentd-personal.sock"; handler: Socket {} }
  AgentdState {
    id: state
    configuredSockPaths: [Quickshell.env("HOME") + "/agentd-personal.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { test.sent = test.sent.concat([message]); return true }
  }
  FloatingWindow {
    visible: true; implicitWidth: test.narrow ? 360 : 720; implicitHeight: 800
    Rail { id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; focused: true }
  }
  TestEvent { id: input }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function findText(item, text) {
    if (item.text === text) return item
    for (var child of item.children || []) {
      var found = findText(child, text)
      if (found) return found
    }
    return null
  }
  function findNamed(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) {
      var found = findNamed(child, name)
      if (found) return found
    }
    return null
  }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function ask(id, options) {
    event({ type: "extension_ui_request", session: "target", id: id, method: "select",
            title: "Choose one", message: "Choose by clicking or typing", options: options })
  }
  Timer {
    interval: 160; repeat: true; running: true
    onTriggered: {
      if (phase === 0) {
        if (!state.connected) return
        test.event({type:"roster",sessions:[{id:"target",name:"target",cwd:"/tmp",status:"idle",model:"openai/gpt-6-sol"}]})
        rail.jumpToSession("target")
        test.ask("one", ["First choice", "Second choice has a longer description that wraps across the available row"])
      } else if (phase === 1) {
        var label = test.findText(rail, "Second choice has a longer description that wraps across the available row")
        test.check(label && label.height > 0, "select option did not render")
        if (test.deck) {
          test.check(rail.onSteamDeck && test.findText(rail, "RT+A") && test.findText(rail, "RT+B"),
                     "Deck option button hints missing")
        }
        input.mouseClick(label, Math.min(15, label.width / 2), label.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
      } else if (phase === 2) {
        test.check(test.answers.length === 1 && test.answers[0].session === "target"
                   && test.answers[0].response.value === "Second choice has a longer description that wraps across the available row",
                   "clicking the option text did not answer with its full value: " + JSON.stringify(test.sent))
        test.ask("two", ["First choice", "Second choice"])
      } else if (phase === 3) {
        var text = test.findText(rail, "First choice")
        test.check(text && text.parent && text.parent.parent, "first option row did not render")
        var row = text.parent.parent
        test.check(row.border.width === 1 && row.border.color.a > 0, "option outline is missing")
        if (test.narrow) test.check(row.height >= 48, "narrow option tap target is too short")
        input.mouseClick(row, row.width - 4, row.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
      } else if (phase === 4) {
        test.check(test.answers.length === 2 && test.answers[1].response.value === "First choice",
                   "clicking empty space in the option row did not select it")
        test.ask("three", ["First choice", "Second choice"])
        rail.forceActiveFocus()
        input.keyClick(Qt.Key_2, Qt.NoModifier, 0)
      } else if (phase === 5) {
        test.check(test.answers.length === 3 && test.answers[2].response.value === "Second choice",
                   "numeric keyboard shortcut no longer answers")
        test.event({type:"extension_ui_request",session:"target",id:"confirm",method:"confirm",title:"Approve?"})
      } else if (phase === 6) {
        if (test.deck) test.check(test.findText(rail, "RT+A") && test.findText(rail, "RT+B"), "Deck confirm hints missing")
        if (test.narrow) {
          var yes = test.findText(rail, "yes")
          test.check(yes && yes.parent.height >= 48 && yes.parent.width > 100, "narrow yes tap target is too small")
          input.mouseClick(yes.parent, yes.parent.width - 4, yes.parent.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
        } else {
          rail.forceActiveFocus()
          input.keyClick(Qt.Key_1, Qt.NoModifier, 0)
        }
      } else if (phase === 7) {
        test.check(test.answers.length === 4 && test.answers[3].response.confirmed === true, "Deck A/1 must confirm")
        test.event({type:"extension_ui_request",session:"target",id:"confirm-no",method:"confirm",title:"Decline?"})
      } else if (phase === 8) {
        if (test.narrow) {
          var no = test.findText(rail, "no")
          test.check(no && no.parent.height >= 48 && no.parent.width > 100, "narrow no tap target is too small")
          input.mouseClick(no.parent, no.parent.width - 4, no.parent.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
        } else {
          rail.forceActiveFocus()
          input.keyClick(Qt.Key_2, Qt.NoModifier, 0)
        }
      } else if (phase === 9) {
        test.check(test.answers.length === 5 && test.answers[4].response.confirmed === false, "Deck B/2 must decline")
        test.event({type:"extension_ui_request",session:"target",id:"talk",method:"confirm",title:"Discuss?"})
      } else if (phase === 10) {
        var talk = test.findText(rail, "talk about this")
        test.check(talk && talk.visible, "discuss option missing")
        if (test.narrow) {
          test.check(talk.parent.height >= 48 && talk.parent.width > 100, "narrow discuss tap target is too small")
          input.mouseClick(talk.parent, talk.parent.width - 4, talk.parent.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
        } else input.mouseClick(talk, Math.min(10, talk.width / 2), talk.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
      } else if (phase === 11) {
        test.check(test.answers.length === 6 && test.answers[5].response.cancelled === true,
                   "clicking talk did not cancel the question for discussion")
        test.event({type:"ask_answered",session:"target",cancelled:true})
        rail.enterInsert()
      } else if (phase === 12) {
        var hint = test.findText(rail, "⏎")
        if (test.deck) {
          test.check(!hint || !hint.visible, "ordinary chin hints still visible on Deck")
          var chin = test.findNamed(rail, "composerHints")
          var model = chin && test.findText(chin, rail.selectedModelLabel)
          test.check(rail.selectedModelLabel.length && model && model.visible, "Deck chin model name disappeared")
        } else if (!test.narrow) test.check(hint && hint.visible, "desktop chin hints disappeared")
        console.log("PASS: click and number answers, narrow touch targets, Deck question/chin hints")
        Qt.quit()
      }
      phase++
    }
  }
}
