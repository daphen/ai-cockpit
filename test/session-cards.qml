import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import QsLib
import "."

ShellRoot {
  id: test
  property int phase: 0
  property int ticks: 0
  property string opened: ""
  property string ticketAction: ""
  property var originalCard: null
  property real lastPhase: 0
  property real lastChroma: 0
  property string activityLabel: "bash"
  property var originalSessions: []
  property real collapsedHeight: 0
  property real detailTop: 0
  Process {
    running: true
    command: ["python3", "-c", "import os,json; json.dump({'tickets':[{'id':'EVERY-3790','title':'Deterministic canvas actions'},{'id':'EVERY-3789','title':'New components and blocks'}],'session_tickets':[{'id':'EVERY-3710','title':'Update pinned npm packages. '*30},{'id':'EVERY-3711','title':'Default to shadcn and Tailwind'}]},open(os.environ['HOME']+'/cycle.json','w'))"]
  }
  FileView {
    id: cache
    path: Quickshell.env("HOME") + "/cycle.json"
    watchChanges: true; printErrors: false
    onFileChanged: reload()
    adapter: JsonAdapter { property var tickets: []; property var session_tickets: [] }
  }
  FloatingWindow {
    id: window
    visible: true; implicitWidth: 1100; implicitHeight: 1200
    Dashboard {
      id: dash
      anchors.fill: parent
      tickets: cache.adapter.tickets.concat(cache.adapter.session_tickets)
      ticketStates: ({"every-4032":{label:"PR needed",tone:"accent",chips:[],details:"",title:"Title from the session plan"}})
      sessions: [
        {name:"every-3790",scope:"work",profile:"lovable-worker",status:"idle"},
        {name:"every-3789",scope:"work",profile:"lovable-worker",status:"idle"},
        {name:"every-3710",scope:"work",profile:"lovable-worker",status:"idle"},
        {name:"every-3711",scope:"work",profile:"lovable-worker",status:"idle"},
        {name:"orchestrator",scope:"work",profile:"lovable-orchestrator",status:"idle"},
        {name:"personal",scope:"personal",profile:"coding",status:"idle"},
        {name:"disconnected",scope:"work",profile:"lovable-worker",offline:true,status:"offline"}
      ]
      model: ({kind:"home",scope:"lovable",cards:[{title:"TICKETS",rows:[
        {text:"First ticket",action:"ticket:EVERY-3790"},
        {text:"Second ticket",action:"ticket:EVERY-3789"}
      ]}]})
      activityFor: sid => dash.sessions.find(s => s.name === sid).status === "streaming" ? [Theme.green] : []
      activityLabelFor: sid => dash.sessions.find(s => s.name === sid).status === "streaming" ? test.activityLabel : "idle"
      onSessionRequested: sid => test.opened = sid
      onActionRequested: action => test.ticketAction = action
    }
    TextInput { id: railFocus; anchors.right: parent.right; width: 10; height: 10 }
  }
  TestEvent { id: input }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function find(item, predicate) {
    if (predicate(item)) return item
    for (var child of item.children || []) { var match = find(child, predicate); if (match) return match }
    return null
  }
  function card(name) { return find(dash, item => item.objectName === "sessionCard:" + name) }
  function alpha(item) { var value = 1; for (; item; item = item.parent) value *= item.opacity; return value }
  function refresh() { dash.model = Object.assign({}, dash.model) }
  function working(value) {
    dash.sessions = dash.sessions.map(s => Object.assign({}, s, s.name === "every-3790" ? {status:value ? "streaming" : "idle"} : {})).reverse()
  }
  Timer {
    interval: 35; running: true; repeat: true
    onTriggered: {
      if (test.phase === 0) {
        if (dash.tickets.length !== 4) { cache.reload(); return }
        if (++test.ticks < 4) return
        test.ticks = 0
        dash.forceActiveFocus()
        var first = test.card("every-3790"), last = test.card("every-3710")
        test.check(first && last && !test.card("orchestrator") && !test.card("personal") && !test.card("disconnected"), "session membership or default tab is wrong")
        test.check(first.height > first.width && last.y > first.y, "cards are not portrait or grid is wrong")
        for (var name of ["every-3790","every-3789","every-3710","every-3711"]) {
          var c = test.card(name), title = test.find(c,item => item.text === name)
          var summary = test.find(c,item => item.wrapMode === Text.WordWrap)
          test.check(summary && summary.text !== "No ticket summary available", "missing in/out-of-cycle description: " + name)
          test.check(summary.horizontalAlignment === Text.AlignLeft, "description is not left aligned")
          test.check(Math.abs(summary.parent.parent.y + summary.parent.parent.height - (c.height - 60)) < 1, "detail container does not end above the card buttons")
          var firstTitle = test.find(first,item => item.text === "every-3790"), firstSummary = test.find(first,item => item.wrapMode === Text.WordWrap)
          test.check(title.y === firstTitle.y && title.height === firstTitle.height && summary.parent.parent.height === firstSummary.parent.parent.height && Math.abs(summary.parent.parent.y - firstSummary.parent.parent.y) < 0.01 && summary.verticalAlignment === Text.AlignTop, "text containers differ or titles are misaligned: " + JSON.stringify([name,title.y,firstTitle.y,title.height,firstTitle.height,summary.parent.parent.height,firstSummary.parent.parent.height,summary.parent.parent.y,firstSummary.parent.parent.y]))
          var inset = test.find(c,item => item.objectName === "sessionInset")
          test.check(test.find(c,item => item.cardRadius === 18) && Math.abs(inset.width - c.width + 32) < 0.01 && c.radius === 18 && inset.radius === 10 && title.y + title.height < inset.y, "card lacks the raised message-card face or concentric inset/title geometry")
          test.check(!test.find(c,item => item.bevelWidth !== undefined && item.cardRadius !== 18) && title.font.pixelSize === 16, "inner card remains or header is not smaller")
          var status = test.find(c,item => item.objectName === "sessionStatus")
          test.check(Math.abs(status.width - inset.width) < 0.01 && Math.abs(status.y - inset.y) < 0.01 && Math.abs(status.y + status.height + 16 - summary.parent.parent.y) < 0.01, "mesh does not fill the inset above the description")
          test.check(Math.abs(title.x-status.x)<0.01 && Math.abs(summary.parent.parent.x-status.x)<0.01, "header, mesh and description do not share padding")
          test.check(test.find(c,item => item.objectName === "sessionOrb").width > status.width && test.find(c,item => item.objectName === "sessionOrb").flow === 0.35, "mesh is not full-width or 10x slower")
          var tag = test.find(c,item => item.objectName === "sessionActivityBadge")
          test.check(test.find(tag,item => item.text === "IDLE") && Math.abs(tag.x-status.x-12)<0.01 && Math.abs(tag.y+tag.height-status.y-status.height+12)<0.01, "idle badge is not inset at mesh bottom-left")
          test.check(test.find(c,item => item.visible === false && item.radius === inset.radius && Math.abs(item.width-status.width)<0.01 && Math.abs(item.height-status.height)<0.01), "mesh mask does not round all four corners")
          var badge = test.find(c,item => item.objectName === "sessionOrb")
          var center = badge.mapToItem(status,badge.width/2,badge.height/2)
          test.check(Math.abs(center.x-status.width/2)<1 && Math.abs(center.y-status.height/2)<1, "orb is not centered in the upper container")
          var field = test.find(badge,item => item.colB !== undefined)
          test.check(test.alpha(badge) === 1 && !test.find(badge,item => item.text === "IDLE"), "idle orb was hidden or replaced by a label")
          test.check(Math.abs(field.colB.r-field.colB.g)<0.0001 && Math.abs(field.colB.g-field.colB.b)<0.0001, "idle orb is not gray")
          test.check(badge.idleBlur === 1 && field.layer.enabled, "idle orb texture is not softened")
        }
        first.grabToImage(result => result.saveToFile("/tmp/inset-mesh-session-card.png"))
        test.originalSessions = dash.sessions
        test.originalCard = first
        test.lastPhase = test.find(first,item => item.colB !== undefined).ph1
      } else if (test.phase === 1) {
        input.keyClick(Qt.Key_L,Qt.NoModifier,0)
        test.check(dash.currentAction === "session:every-3789", "l did not move right")
        test.refresh(); test.working(true)
        test.check(test.find(test.card("every-3790"),item => item.text === "IDLE"), "badge replaced its text without an exit transition")
      } else if (test.phase === 2) {
        test.check(dash.currentAction === "session:every-3789", "session selection reset on dashboard refresh")
        var c = test.card("every-3790")
        test.check(c === test.originalCard, "activity update recreated the card and broke crossfade")
        test.check(test.card("every-3789").x > c.x && test.card("every-3711").x > test.card("every-3789").x && test.card("every-3710").y > c.y, "unordered status roster reshuffled the cards")
        var orb = test.find(c,item => item.objectName === "sessionOrb"), field = test.find(orb,item => item.colB !== undefined)
        test.check(test.alpha(orb) === 1 && orb.motion > 0 && orb.motion < 1 && Math.abs(field.ph1-test.lastPhase)<0.03, "orb did not ease into motion without a phase jump")
        window.implicitHeight = 520
      } else if (test.phase === 3) {
        if (++test.ticks < 55) return
        input.keyClick(Qt.Key_J,Qt.NoModifier,0)
        test.check(dash.currentAction === "session:every-3710", "j did not move to nearest card below")
        var selected = test.card("every-3710"), position = selected.mapToItem(dash,0,0)
        test.check(position.y >= 0 && position.y + selected.height <= dash.height - 40 + 1, "navigation did not scroll the selected card into view")
        input.keyClick(Qt.Key_H,Qt.NoModifier,0)
        test.check(dash.currentAction === "session:every-3710", "h wrapped across a row boundary")
        input.keyClick(Qt.Key_K,Qt.NoModifier,0)
        test.check(dash.currentAction === "session:every-3790", "k did not move up")
        input.keyClick(Qt.Key_Return,Qt.ControlModifier,0)
        test.check(test.opened === "every-3790", "Ctrl+Enter did not open the selected session")
        var orb = test.find(test.card("every-3790"),item => item.objectName === "sessionOrb")
        var field = test.find(orb,item => item.colB !== undefined)
        test.lastPhase = field.ph1
        test.lastChroma = Math.max(field.colB.r,field.colB.g,field.colB.b) - Math.min(field.colB.r,field.colB.g,field.colB.b)
        test.check(test.find(test.card("every-3790"),item => item.text === "BASH" && item.opacity === 1), "badge did not settle to Bash")
        test.check(orb.motion === 1, "active motion did not reach normal speed")
        test.check(orb.idleBlur === 0 && !field.layer.enabled, "active orb retains blur or an unnecessary effect layer")
        test.card("every-3790").grabToImage(result => result.saveToFile("/tmp/inset-mesh-session-card-active.png"))
        test.working(false); test.ticks = 0
      } else if (test.phase === 4) {
        var orb = test.find(test.card("every-3790"),item => item.objectName === "sessionOrb"), field = test.find(orb,item => item.colB !== undefined)
        if (++test.ticks === 1 && orb.motion === 1) { test.ticks = 0; return }
        if (test.ticks === 1) test.check(orb.motion > 0 && orb.motion < 1 && Math.abs(field.ph1-test.lastPhase)<0.15 && test.alpha(orb) === 1, "idle transition snapped the pattern or hid the orb: " + JSON.stringify([orb.motion,field.ph1-test.lastPhase,test.alpha(orb)]))
        if (test.ticks === 25) {
          var chroma = Math.max(field.colB.r,field.colB.g,field.colB.b) - Math.min(field.colB.r,field.colB.g,field.colB.b)
          test.check(orb.motion > 0 && orb.motion < 0.9 && field.ph1 > test.lastPhase && chroma > 0 && chroma < test.lastChroma, "orb did not gradually slow and desaturate")
          test.check(orb.idleBlur > 0 && orb.idleBlur < 1 && Math.abs(orb.idleBlur + orb.motion - 1) < 0.0001, "blur does not fade in with the spin-down")
        }
        if (test.ticks === 55) {
          test.check(orb.motion === 0 && Math.abs(field.colB.r-field.colB.g)<0.0001 && Math.abs(field.colB.g-field.colB.b)<0.0001, "idle orb did not stop and become gray")
          test.lastPhase = field.ph1
        }
        if (test.ticks < 60) return
        test.check(field.ph1 === test.lastPhase, "idle shader keeps swirling after settling")
        test.working(true); railFocus.forceActiveFocus()
      } else if (test.phase === 5) {
        var orb = test.find(test.card("every-3790"),item => item.objectName === "sessionOrb"), field = test.find(orb,item => item.colB !== undefined)
        test.check(orb.motion > 0 && orb.motion < 1 && Math.abs(field.ph1-test.lastPhase)<0.03, "resuming idle motion jumped the pattern")
        test.check(orb.idleBlur > 0 && orb.idleBlur < 1 && Math.abs(orb.idleBlur + orb.motion - 1) < 0.0001, "blur does not clear continuously when activity resumes")
        test.working(false)
        test.check(!dash.activeFocus, "rail did not get focus")
        test.check(test.find(test.card("every-3790"),item => item.objectName === "sessionRing").border.color === test.find(test.card("every-3789"),item => item.objectName === "sessionRing").border.color, "a card remains highlighted while rail is focused")
        dash.forceActiveFocus(); input.keyClick(Qt.Key_Tab,Qt.NoModifier,0)
      } else if (test.phase === 6) {
        test.check(test.alpha(test.card("every-3790")) === 0 || !test.card("every-3790").visible, "Sessions remained visible under Tickets")
        input.keyClick(Qt.Key_J,Qt.NoModifier,0)
        test.check(dash.currentAction === "ticket:EVERY-3789", "ticket navigation failed")
        test.refresh()
      } else if (test.phase === 7) {
        test.check(dash.currentAction === "ticket:EVERY-3789", "ticket selection reset on recurring model update")
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        test.check(test.ticketAction === "ticket:EVERY-3789", "existing ticket action was not forwarded")
        input.keyClick(Qt.Key_Tab,Qt.NoModifier,0)
        window.implicitWidth = 740
      } else if (test.phase === 8) {
        input.keyClick(Qt.Key_L,Qt.NoModifier,0); input.keyClick(Qt.Key_J,Qt.NoModifier,0)
        test.check(dash.currentAction === "session:every-3710", "navigation did not adapt to two columns")
        dash.sessions = dash.sessions.filter(s => s.name !== "every-3710")
      } else if (test.phase === 9) {
        test.check(!test.card("every-3710") && dash.currentAction === "session:every-3711", "closed session retained a card or invalid selection")
        dash.model = {kind:"home",scope:"personal",cards:[{title:"PLANS",rows:[{text:"Personal plan",action:"plan:p"}]}]}
      } else if (test.phase === 10) {
        test.check(test.card("personal") && test.card("personal").visible && !test.card("every-3790") && !test.find(dash,item => item.text === "Personal plan" && item.visible), "personal home does not lead with personal sessions")
        dash.dispatch("tab")
        test.check(dash.activeTab === "plans" && test.find(dash,item => item.text === "Personal plan" && item.visible), "personal plans tab missing")
        dash.model = {kind:"session",scope:"lovable",tabs:["plan","changes"],activeTab:"plan",cards:[{title:"PLAN",rows:[{text:"Worker plan",action:"plan:p"}]}]}
      } else if (test.phase === 11) {
        test.check(test.find(dash,item => item.text === "Worker plan") && test.find(dash,item => item.text === "CHANGES"), "worker tabs changed")
        dash.model = {kind:"home",scope:"lovable",cards:[]}; dash.sessions = test.originalSessions
        dash.forceActiveFocus()
      } else if (test.phase === 12) {
        input.keyClick(Qt.Key_K,Qt.NoModifier,0)
        var shortCard = test.card("every-3790"), expand = test.find(shortCard,item => item.objectName === "expandSession")
        test.check(!expand.visible && !expand.enabled, "short card still offers Expand")
        test.opened = ""
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        test.check(!expand.visible && test.opened === "", "Enter offered expansion or opened an untruncated card")
        var c = test.card("every-3789")
        input.mouseMove(c,20,20,0,Qt.NoButton,Qt.NoModifier)
      } else if (test.phase === 13) {
        var c = test.card("every-3789")
        var ring = test.find(c,item => item.objectName === "sessionRing")
        test.check(ring && ring.opacity > 0 && Math.abs(ring.border.color.a - 0.3) < 0.01, "mouse hover did not ring the card")
        input.mouseMove(window,1,1,0,Qt.NoButton,Qt.NoModifier)
        input.keyClick(Qt.Key_J,Qt.NoModifier,0)
        var c = test.card("every-3710"), summary = test.find(c,item => item.wrapMode === Text.WordWrap)
        test.check(summary.truncated && summary.elide === Text.ElideRight, "long description did not ellipsize")
        test.check(test.find(c,item => item.objectName === "expandSession").visible, "truncated card lost its Expand control")
        test.collapsedHeight = c.height; test.detailTop = summary.parent.parent.y; test.opened = ""
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
      } else if (test.phase === 14) {
        var c = test.card("every-3710"), summary = test.find(c,item => item.wrapMode === Text.WordWrap)
        var layer = test.find(c,item => item.objectName === "expandedContent"), full = test.find(c,item => item.objectName === "expandedDescription")
        test.check(c.height === test.collapsedHeight && Math.abs(summary.parent.parent.y - test.detailTop) < 0.01 && test.opened === "", "expansion changed card height or opened the session")
        test.check(layer.visible && layer.enabled && layer.opacity > 0 && !full.truncated && full.text === summary.text, "expanded layer did not crossfade in the full text")
        function lum(k) { return [k.r,k.g,k.b].map(x => x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4)).reduce((a,x,i) => a + x * [0.2126,0.7152,0.0722][i], 0) }
        function contrast(a,b) { var x = lum(a), y = lum(b); return (Math.max(x,y) + 0.05) / (Math.min(x,y) + 0.05) }
        Theme.mode = "light"
        var button = test.find(test.find(c,item => item.objectName === "expandSession"),item => item.text === "Collapse")
        test.check(button && contrast(button.color, c.faceMid) >= 4.5, "light-mode button label is unreadable: " + (button && contrast(button.color, c.faceMid)))
        Theme.mode = "dark"
        var scrim = test.find(c,item => item.objectName === "veilScrim"), kids = c.children
        test.check(scrim.visible && scrim.color === c.faceMid && kids.indexOf(test.find(c,item => item.objectName === "collapsedLayer")) < kids.indexOf(scrim) && kids.indexOf(scrim) < kids.indexOf(layer), "expanded text does not sit on an opaque canvas scrim")
        test.check((layer.contentHeight > layer.height) === test.find(c,item => item.objectName === "expandedScrollbar").visible, "scrollbar does not track overflow")
        test.check(test.find(c,item => item.objectName === "expandSession").visible, "expanded card lost its Collapse control")
        test.check(layer.contentHeight > layer.height + 60, "fixture does not overflow the expanded card")
        var maxY = layer.contentHeight - layer.height
        input.keyClick(Qt.Key_J,Qt.NoModifier,0)
        test.check(dash.currentAction === "session:every-3710" && layer.contentY === 60, "j did not scroll inside the expanded card")
        for (var i = 0; i < 40; i++) input.keyClick(Qt.Key_J,Qt.NoModifier,0)
        test.check(layer.contentY === maxY && dash.currentAction === "session:every-3710", "j overshot the expanded card or moved the cursor")
        input.keyClick(Qt.Key_K,Qt.NoModifier,0)
        test.check(layer.contentY === maxY - 60, "k did not scroll up inside the card")
        input.keyClick(Qt.Key_Escape,Qt.NoModifier,0)
        test.check(dash.expandedSession === "", "Esc did not collapse the card")
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        test.check(dash.expandedSession === "every-3710", "Enter did not re-expand")
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0)
        input.keyClick(Qt.Key_K,Qt.NoModifier,0)
        test.check(dash.currentAction !== "session:every-3710", "k did not return to list navigation after collapse")
        input.keyClick(Qt.Key_J,Qt.NoModifier,0)
      } else if (test.phase === 15) {
        var c = test.card("every-3710")
        test.check(c.height === test.collapsedHeight && !test.find(c,item => item.objectName === "expandedContent").enabled, "Enter did not collapse the card")
        input.mouseClick(test.find(c,item => item.objectName === "expandSession"),10,10,Qt.LeftButton,Qt.NoModifier,0)
      } else if (test.phase === 16) {
        var c = test.card("every-3710")
        test.check(test.find(c,item => item.objectName === "expandedContent").enabled && test.opened === "", "Expand button failed or opened the session")
        input.mouseClick(test.find(c,item => item.objectName === "openSession"),10,10,Qt.LeftButton,Qt.NoModifier,0)
      } else if (test.phase === 17) {
        test.check(test.opened === "every-3710", "Open button did not enter the session")
        input.keyClick(Qt.Key_Return,Qt.NoModifier,0); test.opened = ""
      } else if (test.phase === 18) {
        input.mouseClick(test.card("every-3710"),10,10,Qt.LeftButton,Qt.NoModifier,0)
      } else if (test.phase === 19) {
        test.check(test.find(test.card("every-3710"),item => item.objectName === "expandedContent").enabled && test.opened === "", "card click failed to expand or opened the session")
        test.activityLabel = "coding"; test.working(true); test.ticks = 0
      } else if (test.phase === 20 || test.phase === 21) {
        if (++test.ticks < 12) return
        var expected = test.phase === 20 ? "CODING" : "READING"
        test.check(test.find(test.card("every-3790"),item => item.text === expected && item.opacity === 1), "badge did not settle to " + expected)
        if (test.phase === 20) { test.activityLabel = "reading"; test.ticks = 0 }
        else {
          dash.sessions = dash.sessions.concat([{name:"every-4032",scope:"work",profile:"lovable-worker",status:"idle"}])
          test.ticks = 0
        }
      } else if (test.phase === 22) {
        if (++test.ticks < 4) return
        test.check(test.card("every-4032") && test.find(test.card("every-4032"), item => item.text === "Title from the session plan"), "session outside the cycle lost its plan title")
        console.log("PASS: canvas frame, compact shared padding/header/radii, shorter four-corner mesh, 10x slower swirl, animated idle/Bash/Coding/Reading badges, expansion and navigation, plan title fallback")
        Qt.quit()
      }
      test.phase++
    }
  }
}
