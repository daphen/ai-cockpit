import QtQuick
import QtTest
import QsLib
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property string pane: "rail"
  onPaneChanged: pane === "rail" ? rail.forceActiveFocus() : editor.forceActiveFocus()
  AgentdState { id: state; scope: "personal"; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 900; height: 950
    Item {
      id: editor; width: 100; height: parent.height
      onActiveFocusChanged: if (activeFocus) test.pane = "nvim"
      TapHandler { onTapped: editor.forceActiveFocus() }
    }
    Rail {
      id: rail; x: 100; width: parent.width - x; height: parent.height
      agentd: state; scopeMode: "personal"; instanceName: "composer-focus-test"
      focused: test.pane === "rail"
      onRequestFocus: test.pane = "rail"
      onFocusNvim: test.pane = "nvim"
      onActiveFocusChanged: if (activeFocus) test.pane = "rail"
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
  function frame() { return find(rail, item => item.objectName === "composerFrame") }
  function composer() { return find(frame(), item => item.cursorRectangle !== undefined && item.textDocument && !item.readOnly) }
  function selected(item) {
    if (!item || item.visible === false) return 0
    var count = item.cursor === true ? 1 : 0
    for (var child of item.children || []) count += selected(child)
    return count
  }
  function click(item, x, y) { check(!!item, "click target missing"); input.mouseClick(item, x, y, Qt.LeftButton, Qt.NoModifier, 0) }
  function typing() {
    check(composer().activeFocus && rail.insert && rail.imode === "insert" && test.pane === "rail", "composer focus and keyboard mode disagree")
    check(selected(rail) === 0, "rail/roster selection remains active while typing")
  }
  Timer {
    interval: 250; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"},{id:"other",name:"other",cwd:"/tmp",status:"idle"}]}),0)
        rail.jumpToSession("worker")
        state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"worker",data:{leafId:"a",entries:[{id:"a",parentId:null,type:"message",message:{role:"assistant",content:[{type:"text",text:"A focusable agent reply"}]}}]}}),0)
        rail.forceActiveFocus()
      } else if (test.phase === 1) {
        check(selected(rail) > 0, "fixture has no initial rail selection")
        check(frame().children.some(item => item.border && item.border.width === 1 && Qt.colorEqual(item.border.color, Theme.hairline)), "unfocused composer lacks its subtle outline")
        click(composer(), 20, composer().height / 2)
      } else if (test.phase === 2) test.typing()
      else if (test.phase === 4) {
        test.typing()
        check(frame().children.some(item => item.border && item.border.width === 2 && Qt.colorEqual(item.border.color, rail.activeRing)), "focused composer lacks its active outline")
        input.keyClick(Qt.Key_X, Qt.NoModifier, 0)
        var article = find(rail, item => item.turn && item.turn.kind === "turn")
        var card = find(article, item => item.radius === 18 && item.border)
        click(card, 10, 10)
      } else if (test.phase === 5) {
        check(!rail.insert && !composer().activeFocus && rail.activeFocus && selected(rail) > 0, "article click did not leave composer mode: " + JSON.stringify({insert:rail.insert,input:composer().activeFocus,rail:rail.activeFocus,selected:selected(rail),cur:rail.cur,rSize:rail.rSize}))
        click(frame(), 5, 5)
      } else if (test.phase === 6) {
        test.typing()
        check(composer().text === "x", "clicking composer padding lost the draft")
        click(editor, 20, 20)
      } else if (test.phase === 7) {
        check(test.pane === "nvim" && editor.activeFocus && !rail.insert && selected(rail) === 0, "editor focus did not deactivate rail")
        click(composer(), 20, composer().height / 2)
      } else if (test.phase === 8) {
        test.typing()
        check(composer().text === "x", "return from editor lost the draft")
        rail.rosterOverride = true
      } else if (test.phase === 9) {
        var worker = find(rail, item => item.text === "other")
        check(!!worker, "expanded roster missing: " + JSON.stringify({roster:rail.rosterList,sessions:state.sessions,expanded:rail.rosterExpanded,focused:rail.focused}))
        click(worker, 10, worker.height / 2)
      } else if (test.phase === 10) {
        test.typing()
        check(rail.selectedRaw === "other", "roster click did not activate the session")
        input.keyClick(Qt.Key_Escape, Qt.NoModifier, 0)
      } else if (test.phase === 11) {
        check(!rail.insert && !composer().activeFocus && rail.activeFocus, "Escape did not restore exclusive rail focus: " + JSON.stringify({insert:rail.insert,input:composer().activeFocus,rail:rail.activeFocus,selected:selected(rail),cur:rail.cur,rSize:rail.rSize,mode:rail.imode}))
        input.keyClick(Qt.Key_I, Qt.NoModifier, 0)
      } else if (test.phase === 12) {
        test.typing()
        input.keyClick(Qt.Key_Escape, Qt.NoModifier, 0)
      } else if (test.phase === 13) {
        check(!rail.insert && !composer().activeFocus && rail.activeFocus, "keyboard insert/Escape did not restore exclusive rail focus")
        click(editor, 20, 20)
      } else if (test.phase === 14) {
        check(editor.activeFocus && !rail.insert, "normal-mode editor focus failed")
        click(composer(), 20, composer().height / 2)
      } else if (test.phase === 15) {
        test.typing()
        check(composer().text === "x", "normal-mode editor return lost the draft")
        console.log("PASS: composer clicks/padding, article/roster clicks, editor return from typing and normal mode, keyboard insert/Escape, exclusive highlights and preserved drafts")
        Qt.quit()
      }
      test.phase++
    }
  }
}
