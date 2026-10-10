import QtQuick
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property var heading: null
  property var title: null
  property var composer: null
  property var workComposer: null
  property font boldFont: Qt.font({family:"Geist"})
  property font italicFont: Qt.font({family:"Geist"})
  AgentdState { id: state; selectedSession: personal.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 900
    Rail { id: personal; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "personal" }
    Rail { id: work; visible: false; instanceName: "work"; scopeMode: "work" }
  }
  FontInfo { id: resolved; font: Qt.font({family:personal.messageFontFamily, pixelSize:17, weight:400}) }
  FontInfo { id: headingResolved; font: test.heading ? test.heading.font : Qt.font({family:"Geist"}) }
  FontInfo { id: titleResolved; font: test.title ? test.title.font : Qt.font({family:"Geist"}) }
  FontInfo { id: composerResolved; font: test.composer ? test.composer.font : Qt.font({family:"Geist"}) }
  FontInfo { id: workComposerResolved; font: test.workComposer ? test.workComposer.font : Qt.font({family:"Geist"}) }
  FontInfo { id: boldResolved; font: test.boldFont }
  FontInfo { id: italicResolved; font: test.italicFont }
  function check(value, message) { if (!value) throw new Error(message) }
  function label(item, text) {
    if (item.text === text) return item
    for (var child of item.children || []) { var found = label(child, text); if (found) return found }
    return null
  }
  function input(item) {
    if (item.cursorRectangle !== undefined && item.textDocument && !item.readOnly) return item
    for (var child of item.children || []) { var found = input(child); if (found) return found }
    return null
  }
  function find(item) {
    if (item.readOnly === true && typeof item.getText === "function" && item.getText(0,item.length).indexOf("Timeless private preview") >= 0) return item
    for (var child of item.children || []) { var found = find(child); if (found) return found }
    return null
  }
  Timer {
    interval: 250; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        state.onLine(JSON.stringify({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]}),0)
        personal.jumpToSession("worker")
        state.onLine(JSON.stringify({type:"response",command:"get_entries",session:"worker",data:{entries:[
          {type:"message",id:"prompt",parentId:null,message:{role:"user",content:"Try the Timeless family"}},
          {type:"message",id:"answer",parentId:"prompt",message:{role:"assistant",content:[{type:"text",text:"Timeless private preview. A clear paragraph with **bold emphasis**, ***bold italic***, and a <https://example.com> link."}]}}
        ]}}),0)
      } else if (test.phase === 2) {
        test.heading = test.label(personal, "You")
        test.title = test.label(personal, "WORKER")
        test.composer = test.input(personal)
        test.workComposer = test.input(work)
        var prose = test.find(personal), text = prose.getText(0,prose.length)
        var bold = text.indexOf("bold emphasis")
        prose.select(bold,bold+"bold emphasis".length)
        test.boldFont = prose.cursorSelection.font
        var italic = text.indexOf("bold italic")
        prose.select(italic,italic+"bold italic".length)
        test.italicFont = prose.cursorSelection.font
        prose.deselect()
      } else if (test.phase === 4) {
        test.check(personal.messageFontFamily === "Timeless Sans Sans", "private font did not load: " + personal.messageFontFamily)
        test.check(resolved.family === "Timeless Sans Sans", "Qt substituted another font: " + resolved.family)
        test.check(resolved.styleName === "Sans Regular", "wrong Timeless variant: " + resolved.styleName)
        var prose = test.find(personal)
        test.check(prose && prose.font.family === "Timeless Sans Sans" && prose.font.pixelSize === 17, "private prose lost its font or size")
        test.check(test.heading && headingResolved.styleName === "Grotesk Semibold", "message heading is not real Grotesk Semibold: " + headingResolved.styleName)
        test.check(test.title && titleResolved.family.toLowerCase().indexOf("berkeley") >= 0, "bottom pane title is not Berkeley: " + titleResolved.family)
        test.check(test.composer && test.workComposer && composerResolved.family === workComposerResolved.family && composerResolved.family.toLowerCase().indexOf("berkeley") >= 0, "private composer does not match work Berkeley: " + composerResolved.family + " / " + workComposerResolved.family)
        test.check(boldResolved.styleName === "Sans Bold", "bold emphasis is not the real Sans Bold face: " + boldResolved.styleName)
        test.check(italicResolved.styleName === "Sans Bold Italic", "bold italic lost its italic face: " + italicResolved.styleName)
        var plain = prose.getText(0,prose.length), linkPos = plain.indexOf("https://example.com")
        var linkRect = prose.positionToRectangle(linkPos+1)
        var href = prose.linkAt(linkRect.x+2,linkRect.y+linkRect.height/2)
        test.check(href === "https://example.com", "bold formatting damaged the adjacent link: " + href + " " + JSON.stringify(linkRect) + " " + plain)
        test.check(work.messageFontFamily === "Geist" && work.labelFontFamily !== "Timeless Sans", "work font changed")
        console.log("PASS: private prose uses real Sans Regular/Bold/Bold Italic; conversation headings retain Grotesk; bottom pane/composer resolve to the same Berkeley as work")
        Qt.quit()
      }
      test.phase++
    }
  }
}
