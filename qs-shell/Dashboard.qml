import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import QsLib

FocusScope {
  id: root

  // Light fg_muted is 2.6:1 on the canvas; pull it toward fg_secondary to clear 4.5:1.
  readonly property color muted: Theme.mode === "light" ? Qt.rgba(Theme.fg_muted.r * 0.4 + Theme.fg_secondary.r * 0.6, Theme.fg_muted.g * 0.4 + Theme.fg_secondary.g * 0.6, Theme.fg_muted.b * 0.4 + Theme.fg_secondary.b * 0.6, 1) : Theme.fg_muted
  property var model: ({})
  property var sessions: []
  property var tickets: []
  property var ticketStates: ({})
  property var askFor: sid => null
  property var answerSendingFor: sid => false
  property double statusClock: Date.now()
  Timer { interval: 15000; repeat: true; running: root.enabled && root.showSessions; onTriggered: root.statusClock = Date.now() }
  property var activityFor: sid => []
  property var activityLabelFor: sid => "idle"
  property var taskFor: sid => ""
  property string homeTab: "sessions"
  property string expandedSession: ""
  property string focusedQuestion: ""
  property int cursor: 0
  property string focusedSession: ""
  readonly property string project: {
    var focused = sessions.find(s => s.name === focusedSession)
    return focused && focused.project && !focused.parent ? focused.project : ""
  }
  readonly property bool personalHome: model.scope === "personal"
  readonly property bool sessionHome: !project && model.kind === "home" && (model.scope === "lovable" || personalHome)
  readonly property string homeOtherTab: personalHome ? "plans" : "tickets"
  readonly property bool showSessions: !!project || (sessionHome && homeTab !== homeOtherTab)
  readonly property var groupNames: ["NEEDS YOU", "WORKING", "READY"]
  function groupOf(s) {
    if (!project) return -1
    if (askFor(s.name)) return 0
    return s.status === "streaming" || !(s.costUsd > 0) ? 1 : 2
  }
  readonly property var workers: project
    ? sessions.filter(s => s.project === project && s.name !== focusedSession && !s.offline)
        .sort((a, b) => groupOf(a) - groupOf(b) || a.name.localeCompare(b.name))
    : personalHome
    ? sessions.filter(s => s.scope === "personal" && !s.offline && !s.parent)
        .sort((a, b) => a.name.localeCompare(b.name))
    : sessions.filter(s => s.scope === "work" && !s.offline && s.profile === "lovable-worker" && !s.parent)
        .sort((a, b) => b.name.localeCompare(a.name))
  readonly property string workerNames: workers.map(s => s.name).join("\n")
  readonly property var workerGroups: workers.map(s => groupOf(s))
  readonly property var tabs: sessionHome ? ["sessions", homeOtherTab] : project ? [] : (model.tabs || [])
  readonly property string activeTab: sessionHome ? (showSessions ? "sessions" : homeOtherTab) : (model.activeTab || "")
  readonly property var visibleActions: showSessions
    ? [{ key: "Enter", label: "expand / collapse", id: "expand-card" }, { key: "Ctrl+Enter", label: "open session", id: currentAction }]
        .concat(sessionHome ? [{ key: "Tab", label: homeOtherTab, id: "tab:" + homeOtherTab }] : [])
    : (model.actions || [])
  signal sessionRequested(string sid)
  signal prRequested(string url)
  signal answerRequested(string sid, var payload)
  signal promptRequested(string sid, string text)
  signal actionRequested(string actionId)
  signal focusRequested(string direction)

  readonly property var selectable: {
    var out = []
    if (showSessions) return workers.map(s => "session:" + s.name)
    var cards = model.cards || []
    for (var i = 0; i < cards.length; i++) {
      var rows = cards[i].rows || []
      for (var j = 0; j < rows.length; j++)
        if (rows[j].action) out.push(rows[j].action)
    }
    return out
  }
  readonly property string currentAction: selectable.length
    ? selectable[Math.max(0, Math.min(cursor, selectable.length - 1))] : ""

  function tone(name) {
    if (name === "accent") return "#C4B5FD"
    if (name === "error") return Theme.red
    if (name === "success") return Theme.green
    if (name === "muted") return root.muted
    return Theme.fg
  }
  function changeParts(text) {
    var match = String(text || "").match(/^(.*?\S)\s+(\+\d+)\s+(-\d+)\s*$/)
    if (!match) return null
    return {
      label: match[1].replace(/^•\s*/, ""),
      additions: match[2],
      removals: match[3]
    }
  }
  function moveCard(horizontal, vertical) {
    if (!workers.length) return
    var current = Math.min(cursor, workers.length - 1)
    var columns = sessionCards.columns
    var column = current % columns
    var row = Math.max(0, Math.min(Math.ceil(workers.length / columns) - 1, Math.floor(current / columns) + vertical))
    var lastColumn = Math.min(columns - 1, workers.length - 1 - row * columns)
    cursor = row * columns + Math.max(0, Math.min(lastColumn, column + horizontal))
  }
  function move(delta) {
    if (showSessions) { moveCard(0, delta); return }
    if (!selectable.length) return
    cursor = (Math.min(cursor, selectable.length - 1) + delta + selectable.length) % selectable.length
  }
  function dispatch(id) {
    if (sessionHome && (id === "tab" || id.indexOf("tab:") === 0)) {
      homeTab = id === "tab" ? (showSessions ? homeOtherTab : "sessions") : id.slice(4)
      cursor = 0
    } else if (showSessions && id === "expand-card") activate(false)
    else if (showSessions && id.indexOf("session:") === 0) sessionRequested(id.slice(8))
    else if (id) actionRequested(id)
  }
  function summary(sid) {
    var id = sid.toUpperCase()
    for (var ticket of tickets)
      if (ticket.id.toUpperCase() === id) return ticket.title
    return (ticketStates[sid] || {}).title || taskFor(sid) || (personalHome ? "No task yet" : "No ticket summary available")
  }
  function ticketState(sid) {
    var session = personalHome ? sessions.find(s => s.name === sid) : null
    var state = ticketStates[sid] || {label:session ? String(session.cwd || "").replace(/^\/home\/[^/]+/, "~") : "Status unknown", tone:"muted", chips:[], details:""}
    if (state.checkedAt && statusClock - state.checkedAt > 120000)
      state = Object.assign({}, state, {label:"Status stale", tone:"muted"})
    var ask = askFor(sid)
    return ask ? Object.assign({}, state, {label:ask.method === "confirm" ? "Approval needed" : "Input needed", tone:"accent"}) : state
  }
  component TicketSummary: Column {
    id: summary
    property var ticket: ({})
    property int limit: 2
    height: 30 + supporting.height
    spacing: 6
    Rectangle {
      width: parent.width; height: 24
      color: "transparent"
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 6; height: 6; radius: 3
        color: root.tone(summary.ticket.tone)
      }
      Text {
        id: statusLabel
        objectName: "ticketStatusLabel"
        anchors { fill: parent; leftMargin: 15 }
        verticalAlignment: Text.AlignVCenter
        text: summary.ticket.label; textFormat: Text.PlainText; elide: Text.ElideRight
        color: root.tone(summary.ticket.tone)
        font { family: Theme.fontFamily; pixelSize: 13; weight: 600 }
      }
    }
    Flow {
      id: supporting
      visible: (summary.ticket.chips || []).length > 0
      width: parent.width; height: visible ? Math.max(24, implicitHeight) : 0
      spacing: 6
      Repeater {
        model: (summary.ticket.chips || []).slice(0, summary.limit)
        delegate: Rectangle {
          required property var modelData
          width: Math.min(supporting.width, chipLabel.implicitWidth + 16); height: 24; radius: 6
          color: modelData.tone === "error" ? Qt.rgba(Theme.red.r, Theme.red.g, Theme.red.b, 0.10)
            : (chipHover.hovered && modelData.url ? Theme.hairline : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.045))
          Text {
            id: chipLabel
            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
            verticalAlignment: Text.AlignVCenter
            text: modelData.label; textFormat: Text.PlainText; elide: Text.ElideRight
            color: modelData.tone === "error" ? Theme.red : root.muted
            font { family: Theme.fontFamily; pixelSize: 12 }
          }
          HoverHandler { id: chipHover; cursorShape: modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor }
          MouseArea { anchors.fill: parent; enabled: !!modelData.url; onClicked: root.prRequested(modelData.url) }
        }
      }
    }
  }
  function syncPrompt(ticket) {
    return "Cockpit: David pressed Sync on this card. Your local HEAD " + ticket.localHead + " differs from PR #" + ticket.pr
      + " head " + ticket.prHead + " on " + ticket.branch + ". Fetch, then: if local strictly contains the PR head, push without force;"
      + " if the PR head strictly contains local, fast-forward local. Both are approved by this press. If they diverged, do not push,"
      + " rebase or reset: ask David with the commits on each side. Report the final shared SHA."
  }
  function detailRows(details) {
    var rows = [], seen = {}
    var labels = {"Claude review on PR head":"Claude review", "Human approval on PR head":"Human review", "GitHub approval gate":"Review gate", "Unresolved review threads":"Open threads"}
    for (var line of String(details || "").split("\n")) {
      if (!line.length) continue
      if (line.indexOf("Checked ") === 0) { rows.push({label:"Updated", value:line.slice(8)}); continue }
      var split = line.indexOf(":"), label = split < 0 ? "Status" : line.slice(0, split)
      var value = split < 0 ? line : line.slice(split + 1).trim()
      seen[label] = value
      if (label === "Plan branch" && value === seen["Branch"]) continue
      if (label === "Branch" && value === seen["Plan branch"]) { rows = rows.filter(row => row.label !== "Plan branch"); }
      if (label === "Unresolved review threads" && value === "0") continue
      if (value === "not recorded") value = "pending"
      if (value === "REVIEW_REQUIRED") value = "review required"
      if (value === "APPROVED") value = "approved"
      rows.push({label:labels[label] || label, value:value.replace(/^implementing; /, "implementing \u00b7 ")})
    }
    return rows
  }
  function confirmHovered(value) {
    var target = null
    for (var i = 0; i < sessionRows.count && !target; i++) {
      var card = sessionRows.itemAt(i)
      if (card && card.hovered) target = card
    }
    if (!target) target = sessionRows.itemAt(selectable.indexOf(currentAction))
    if (!target || target.expanded || !target.ask || target.ask.method !== "confirm" || target.answerSending) return false
    answerRequested(target.modelData, {confirmed:value})
    return true
  }
  property bool caretHeld: false
  property int layoutTick: 0
  onModelChanged: Qt.callLater(() => layoutTick++)
  onSessionsChanged: Qt.callLater(() => layoutTick++)
  onWidthChanged: Qt.callLater(() => layoutTick++)
  readonly property var restPoint: {
    layoutTick; view.contentY; height
    return activeFocus && currentAction ? cursorPoint() : null
  }
  function cursorPoint() {
    if (!currentAction) return null
    if (showSessions) {
      var card = sessionRows.itemAt(selectable.indexOf(currentAction)), title = card && card.titleItem
      return title && card.visible ? title.mapToItem(root, Math.min(title.implicitWidth, title.width) + 12, 10) : null
    }
    var item = findRow(content)
    return item && item.visible ? item.mapToItem(root, -14, item.height / 2) : null
  }
  function findRow(item) {
    if (item.objectName === "dashRow:" + currentAction) return item
    for (var child of item.children || []) { var match = findRow(child); if (match) return match }
    return null
  }
  function revealCard() {
    if (!showSessions || !activeFocus) return
    var item = sessionRows.itemAt(selectable.indexOf(currentAction))
    if (!item) return
    var top = content.y + sessionCards.y + item.y
    if (top < view.contentY) view.contentY = top
    else if (top + item.height > view.contentY + view.height)
      view.contentY = top + item.height - view.height
  }
  function expandedCard() {
    var sid = expandedSession || focusedQuestion
    var card = sid ? sessionRows.itemAt(selectable.indexOf("session:" + sid)) : null
    return card && (card.expanded || card.asking) ? card : null
  }
  function reapCard() {
    var card = sessionRows.itemAt(selectable.indexOf(currentAction))
    return card && card.action === "reap" ? card : null
  }
  function toggleCard(sid) {
    var card = sessionRows.itemAt(selectable.indexOf("session:" + sid))
    if (card && card.asking) focusedQuestion = focusedQuestion === sid ? "" : sid
    else if (card && card.canExpand) expandedSession = expandedSession === sid ? "" : sid
  }
  function activate(openSession) {
    if (showSessions && !openSession && currentAction) toggleCard(currentAction.slice(8))
    else dispatch(currentAction)
  }
  function shortcut(text) {
    if (text === "i") { dispatch("key:i"); return true }
    var actions = model.actions || []
    for (var i = 0; i < actions.length; i++) {
      if (actions[i].key === text) { dispatch(actions[i].id); return true }
    }
    return false
  }

  Keys.onPressed: event => {
    if (showSessions && !event.isAutoRepeat && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) && (event.key === Qt.Key_Y || event.key === Qt.Key_N) && confirmHovered(event.key === Qt.Key_Y)) event.accepted = true
    else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_L) { focusRequested("right"); event.accepted = true }
    else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_H) { focusRequested("left"); event.accepted = true }
    else if (showSessions && event.key === Qt.Key_H) { moveCard(-1, 0); event.accepted = true }
    else if (showSessions && event.key === Qt.Key_L) { moveCard(1, 0); event.accepted = true }
    else if (showSessions && expandedCard() && (event.key === Qt.Key_J || event.key === Qt.Key_K)) { expandedCard().scrollBy(event.key === Qt.Key_J ? 60 : -60); event.accepted = true }
    else if (showSessions && event.key === Qt.Key_D && !event.modifiers && reapCard()) { reapCard().runAction(); event.accepted = true }
    else if (showSessions && expandedCard() && event.key === Qt.Key_Escape) { expandedSession = ""; focusedQuestion = ""; event.accepted = true }
    else if (event.key === Qt.Key_J || event.text === "j") { move(1); event.accepted = true }
    else if (event.key === Qt.Key_K || event.text === "k") { move(-1); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { activate(!!(event.modifiers & Qt.ControlModifier)); event.accepted = true }
    else if (event.text === "o") { activate(true); event.accepted = true }
    else if (event.key === Qt.Key_Tab) { dispatch("tab"); event.accepted = true }
    else if (shortcut(event.text)) event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.bg
  }

  function assetUrl(name) {
    var dir = Quickshell.env("COCKPIT_ASSET_DIR") || ""
    return dir ? "file://" + dir + "/" + name : ""
  }

  Flickable {
    id: view
    anchors { fill: parent; bottomMargin: hints.height }
    contentWidth: width
    contentHeight: content.implicitHeight + 56
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      width: Math.max(320, Math.min(view.width - 64, 980))
      x: Math.round((view.width - width) / 2)
      y: 36
      spacing: 24

      Image {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.model.masthead === "lovable"
        width: Math.min(parent.width * 0.36, 350)
        height: visible ? width * 0.233 : 0
        source: visible ? root.assetUrl("lovable-" + Theme.mode + ".png") : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        height: visible ? 34 : 0
        spacing: 8
        visible: root.tabs.length > 1
        Repeater {
          model: root.tabs
          delegate: Rectangle {
            id: dashTab
            required property string modelData
            readonly property bool active: modelData === root.activeTab
            width: tabText.implicitWidth + 24
            height: 30
            radius: 9
            color: !active && dashTabHover.hovered ? Theme.itemHover : Qt.alpha(Theme.itemHover, 0)
            Behavior on color { ColorAnimation { duration: 140 } }
            GradientFrame {
              anchors.fill: parent
              visible: dashTab.active && Theme.mode !== "light"
              radius: dashTab.radius
              fill: Qt.tint(Theme.bg, Theme.itemSelected)
              edge: Theme.fg
            }
            LightKey {
              anchors.fill: parent
              visible: dashTab.active && Theme.mode === "light"
              radius: dashTab.radius
              outline: Qt.alpha(Theme.fg, 0.16)
            }
            Text {
              id: tabText
              anchors.centerIn: parent
              text: modelData.toUpperCase()
              color: dashTab.active || dashTabHover.hovered ? Theme.fg : root.muted
              font { family: Theme.fontFamily; pixelSize: 15; weight: 600 }
            }
            HoverHandler { id: dashTabHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.dispatch("tab:" + modelData) }
          }
        }
      }

      Item {
        id: sessionCards
        width: content.width
        height: {
          if (!visible) return 0
          var bottom = 0
          for (var i = 0; i < sessionRows.count; i++) {
            var card = sessionRows.itemAt(i)
            if (card) bottom = Math.max(bottom, card.y + card.height)
          }
          return bottom
        }
        visible: root.showSessions
        readonly property real spacing: 20
        readonly property real headerHeight: 30
        readonly property int columns: Math.max(1, Math.min(3, Math.floor((width + spacing) / 300)))
        Connections {
          target: root
          function onCurrentActionChanged() { root.revealCard() }
        }
        Repeater {
          model: root.project ? [0, 1, 2] : []
          delegate: Text {
            required property int modelData
            readonly property int start: root.workerGroups.indexOf(modelData)
            readonly property Item first: sessionRows.count && start >= 0 ? sessionRows.itemAt(start) : null
            objectName: "groupHeader:" + root.groupNames[modelData]
            visible: !!first
            y: first ? first.y - sessionCards.headerHeight : 0
            text: root.groupNames[modelData] + " \u00b7 " + root.workerGroups.filter(g => g === modelData).length
            color: root.muted
            font { family: Theme.fontFamily; pixelSize: 13; weight: 600; letterSpacing: 1 }
          }
        }
        Repeater {
          id: sessionRows
          model: root.workerNames ? root.workerNames.split("\n") : []
          delegate: Card {
            id: sessionCard
            required property string modelData
            required property int index
            objectName: "sessionCard:" + modelData
            readonly property Item titleItem: sessionName
            readonly property int group: root.workerGroups[index] === undefined ? -1 : root.workerGroups[index]
            readonly property int groupStart: root.workerGroups.indexOf(group)
            readonly property int slot: index - groupStart
            x: (slot % sessionCards.columns) * (width + sessionCards.spacing)
            y: {
              sessionRows.count
              if (slot >= sessionCards.columns) {
                var above = sessionRows.itemAt(index - sessionCards.columns)
                return above ? above.y + above.height + sessionCards.spacing : 0
              }
              var top = 0
              for (var i = 0; i < groupStart; i++) {
                var earlier = sessionRows.itemAt(i)
                if (earlier) top = Math.max(top, earlier.y + earlier.height + sessionCards.spacing)
              }
              return top + (group >= 0 ? sessionCards.headerHeight : 0)
            }
            readonly property var activity: root.activityFor(modelData)
            readonly property bool expanded: root.expandedSession === modelData
            readonly property var ticket: reaping ? Object.assign({}, root.ticketState(modelData), {label:"Reaping\u2026", tone:"accent"})
              : reapState === "failed" ? Object.assign({}, root.ticketState(modelData), {label:"Reap failed", tone:"error"})
              : root.ticketState(modelData)
            readonly property var ask: root.askFor(modelData)
            readonly property bool answerSending: root.answerSendingFor(modelData)
            readonly property bool hovered: cardHover.hovered
            readonly property var subagents: root.sessions.filter(s => s.parent === modelData && !s.offline)
            readonly property var session: root.sessions.find(s => s.name === modelData) || ({})
            readonly property string action: ticket.action === "reap" ? (session.scope === "work" ? "reap" : "")
              : ticket.action === "claude-review" && (claudeRequestedFor === String(ticket.pr) || claudeReviewPost.running) ? ""
              : (ticket.action || "")
            function scrollBy(px) {
              if (asking) { questionScroll.scrollBy(px); return }
              expandedContent.contentY = Math.max(0, Math.min(expandedContent.contentHeight - expandedContent.height, expandedContent.contentY + px))
            }
            property bool actionArmed: false
            property string actionMessage: ""
            property bool actionError: false
            Timer { id: disarm; interval: 4000; onTriggered: sessionCard.actionArmed = false }
            readonly property string reapUnit: "cockpit-reap-" + modelData
            property string reapState: ""
            property string reapLine: ""
            readonly property bool reaping: reapState === "active" || reapState === "activating" || reapStart.running
            Process {
              id: reapStart
              objectName: "reapProcess"
              command: ["sh", "-c", 'systemctl --user reset-failed "$1" 2>/dev/null; exec systemd-run --user --quiet --unit "$1" --working-directory="$HOME" --setenv=PATH="$PATH" ${SSH_AUTH_SOCK:+--setenv=SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} "$(command -v vm-wt)" --reap "$2"',
                "sh", sessionCard.reapUnit, sessionCard.modelData.toUpperCase()]
              stderr: StdioCollector { id: reapStartErr }
              onExited: code => {
                if (code !== 0) { sessionCard.actionError = true; sessionCard.actionMessage = "Reap did not start: " + reapStartErr.text.trim() }
                reapPoll.running = true
              }
            }
            Process {
              id: reapPoll
              command: ["sh", "-c", 'systemctl --user is-active "$1"; journalctl --user -u "$1" -n 20 -o cat --no-pager 2>/dev/null | grep -v -e "^$1" -e "^Started \\[systemd-run\\]" -e "^: exit status" | tail -n 1', "sh", sessionCard.reapUnit]
              stdout: StdioCollector {
                onStreamFinished: {
                  var lines = text.trim().split("\n")
                  sessionCard.reapState = lines[0] === "inactive" ? "" : lines[0]
                  sessionCard.reapLine = lines.slice(1).join(" ").trim()
                }
              }
            }
            Timer {
              interval: sessionCard.reaping ? 1500 : 10000
              running: sessionCard.action === "reap" || sessionCard.reapState !== ""
              repeat: true; triggeredOnStart: true
              onTriggered: if (!reapStart.running) reapPoll.running = true
            }
            property string claudeRequestedFor: ""
            Process {
              id: claudeReviewPost
              objectName: "claudeReviewPost"
              command: ["gh", "pr", "comment", String(sessionCard.ticket.pr), "--repo", String(sessionCard.ticket.repo), "--body", "@claude review"]
              stderr: StdioCollector { id: claudeReviewErr }
              onExited: code => {
                sessionCard.actionError = code !== 0
                sessionCard.actionMessage = code === 0 ? "Claude review requested" : "Request failed: " + claudeReviewErr.text.trim()
                if (code === 0) sessionCard.claudeRequestedFor = String(sessionCard.ticket.pr)
              }
            }
            function runAction() {
              if (reaping) return
              if (!actionArmed) { actionArmed = true; disarm.restart(); return }
              actionArmed = false; actionError = false
              if (action === "reap") { actionMessage = ""; reapStart.running = true }
              else if (action === "claude-review") { actionMessage = "Requesting Claude review\u2026"; claudeReviewPost.running = true }
              else { root.promptRequested(modelData, root.syncPrompt(ticket)); actionMessage = "Sync sent to " + modelData }
            }
            readonly property bool canExpand: description.truncated || !!ticket.details || (ticket.chips || []).length > 2
            property real reveal: expanded ? 1 : 0
            readonly property bool asking: !!ask && !expanded
            property real askReveal: asking ? 1 : 0
            Behavior on askReveal { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            readonly property real veil: Math.max(reveal, askReveal)
            readonly property var answers: !ask ? [] : ask.method === "confirm"
              ? [{label:"Yes", key:"Y", response:{confirmed:true}}, {label:"No", key:"N", response:{confirmed:false}}]
              : ask.method === "select" ? (ask.options || []).map(option => ({label:String(option), response:{value:option}}))
              : [{label:"Answer in session", open:true}]
            function answer(choice) {
              if (choice.open) root.sessionRequested(modelData)
              else root.answerRequested(modelData, choice.response)
            }
            Behavior on reveal { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            onHeightChanged: if (expanded) Qt.callLater(root.revealCard)
            width: (sessionCards.width - sessionCards.spacing * (sessionCards.columns - 1)) / sessionCards.columns
            height: Math.max(width * 1.35, 350) + Math.max(0, ticketBadges.height - 54)
            radius: 18
            readonly property bool lightFace: Theme.mode === "light"
            readonly property color faceMid: lightFace ? "#F8F8F9" : Qt.lighter(Theme.surface0, 1.2)
            color: "transparent"
            ContrastCard {
              z: -1
              anchors.fill: parent
              cardRadius: sessionCard.radius
              elevated: true
              bevelWidth: sessionCard.lightFace ? 1 : 2
              faceTop: sessionCard.lightFace ? "#FDFDFD" : Qt.lighter(Theme.surface0, 1.25)
              faceUpper: sessionCard.lightFace ? "#FCFCFC" : faceTop
              faceMid: sessionCard.faceMid
              faceBottom: sessionCard.lightFace ? "#F3F3F4" : faceMid
              rimTop: sessionCard.lightFace ? "#FFFFFF" : "#2B2B2B"
              rimBottom: sessionCard.lightFace ? "#F3F3F4" : "#222222"
              outlineColor: sessionCard.lightFace ? Qt.alpha(Theme.fg, 0.11) : "#282828"
              shadowColor: sessionCard.lightFace ? Qt.rgba(0.12, 0.15, 0.18, 0.07) : "#101010"
            }
            LightKey {
              z: -1
              anchors.fill: parent
              visible: sessionCard.lightFace
              radius: sessionCard.radius
              outline: Qt.alpha(Theme.fg, 0.16)
            }
            Rectangle {
              objectName: "sessionRing"
              z: 2
              anchors.fill: parent
              radius: sessionCard.radius
              color: "transparent"
              border.width: 1
              border.color: root.activeFocus && "session:" + modelData === root.currentAction ? root.muted : Qt.alpha(Theme.fg, 0.3)
              opacity: (root.activeFocus && "session:" + modelData === root.currentAction) || cardHover.hovered ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            }
            Item {
              id: sessionInset
              objectName: "sessionInset"
              anchors { left: parent.left; right: parent.right; top: sessionName.bottom; bottom: parent.bottom; leftMargin: 16; rightMargin: 16; topMargin: 10; bottomMargin: 16 }
              readonly property real radius: 10
            }
            HoverHandler {
              id: cardHover
              cursorShape: sessionCard.canExpand ? Qt.PointingHandCursor : Qt.ArrowCursor
              onHoveredChanged: if (hovered && sessionCard.ask && sessionCard.ask.method === "confirm") root.forceActiveFocus()
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: sessionCard.canExpand ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: {
                root.cursor = root.selectable.indexOf("session:" + sessionCard.modelData)
                root.forceActiveFocus()
                root.toggleCard(sessionCard.modelData)
              }
            }
            Text {
              id: sessionName
              anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 16 }
              height: 22
              text: sessionCard.modelData
              textFormat: Text.PlainText
              elide: Text.ElideRight
              verticalAlignment: Text.AlignTop
              color: Theme.fg
              font { family: Theme.fontFamily; pixelSize: 16; weight: 650 }
            }
            Item {
              id: collapsedLayer
              objectName: "collapsedLayer"
              anchors.fill: parent
              enabled: !sessionCard.expanded && !sessionCard.asking
              opacity: 1 - 0.55 * sessionCard.veil
              layer.enabled: sessionCard.veil > 0
              layer.effect: MultiEffect { blurEnabled: true; blur: sessionCard.veil; blurMax: 64; autoPaddingEnabled: false }
              Item { id: insetBox; x: sessionInset.x; y: sessionInset.y; width: sessionInset.width; height: sessionInset.height }
              Rectangle {
                id: meshMask
                width: meshPanel.width; height: meshPanel.height
                radius: sessionInset.radius
                color: "white"
                visible: false
                layer.enabled: true
              }
              Item {
                id: meshPanel
                objectName: "sessionStatus"
                anchors { left: insetBox.left; right: insetBox.right; top: insetBox.top; bottom: sessionDetails.top; bottomMargin: 16 }
                clip: true
                layer.enabled: true
                layer.effect: MultiEffect { maskEnabled: true; maskSource: meshMask }
                ThinkingOrb {
                  id: sessionOrb
                  objectName: "sessionOrb"
                  anchors.centerIn: parent
                  width: Math.sqrt(parent.width * parent.width + parent.height * parent.height) * 1.25
                  height: width
                  running: sessionCards.visible
                  seedKey: sessionCard.modelData
                  activityColors: sessionCard.activity
                  glow: activityColors.length ? activityColors[0] : "#999999"
                  colorDuration: 1600
                  property real motion: sessionCard.activity.length ? 1 : 0
                  idleBlur: 1 - motion
                  property real elapsed: 0
                  clockNow: elapsed
                  flow: 0.35
                  Behavior on motion { NumberAnimation { duration: 1800; easing.type: Easing.InOutCubic } }
                  FrameAnimation {
                    running: sessionOrb.visible && sessionOrb.motion > 0
                    onTriggered: sessionOrb.elapsed += frameTime * 1000 * sessionOrb.motion
                  }
                }
              }
              Rectangle {
                id: activityBadge
                objectName: "sessionActivityBadge"
                anchors { left: meshPanel.left; bottom: meshPanel.bottom; margins: 12 }
                width: Math.min(meshPanel.width - 24, badgeText.implicitWidth + 24)
                height: 26; radius: 6
                color: Qt.rgba(0, 0, 0, 0.2)
                border { width: 1; color: Qt.rgba(1, 1, 1, 0.38) }
                Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                Text {
                  id: badgeText
                  anchors.centerIn: parent
                  width: parent.width - 24
                  text: String(root.activityLabelFor(sessionCard.modelData)).toUpperCase()
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  horizontalAlignment: Text.AlignHCenter
                  color: "white"
                  font { family: Theme.fontFamily; pixelSize: 12; weight: 650 }
                  property real shift: 0
                  property real motionBlur: 0
                  transform: Translate { y: badgeText.shift }
                  layer.enabled: badgeSwap.running
                  layer.effect: MultiEffect { blurEnabled: true; blurMax: 16; blur: badgeText.motionBlur }
                  Behavior on text {
                    SequentialAnimation {
                      id: badgeSwap
                      ParallelAnimation {
                        NumberAnimation { target: badgeText; property: "opacity"; to: 0; duration: 100; easing.type: Easing.InOutQuad }
                        NumberAnimation { target: badgeText; property: "shift"; to: -3; duration: 100; easing.type: Easing.OutCubic }
                        NumberAnimation { target: badgeText; property: "motionBlur"; to: 0.125; duration: 100 }
                      }
                      PropertyAction {}
                      PropertyAction { target: badgeText; property: "shift"; value: 3 }
                      ParallelAnimation {
                        NumberAnimation { target: badgeText; property: "opacity"; to: 1; duration: 150; easing.type: Easing.InOutQuad }
                        NumberAnimation { target: badgeText; property: "shift"; to: 0; duration: 150; easing.type: Easing.OutCubic }
                        NumberAnimation { target: badgeText; property: "motionBlur"; to: 0; duration: 150 }
                      }
                    }
                  }
                }
              }
              Row {
                objectName: "subagentIndicators"
                visible: opacity > 0
                anchors { right: meshPanel.right; bottom: meshPanel.bottom; margins: 12 }
                spacing: 6
                Repeater {
                  model: sessionCard.subagents
                  delegate: Rectangle {
                    id: subagentIndicator
                    required property var modelData
                    objectName: "subagent:" + modelData.name
                    width: 26; height: 26; radius: 13
                    color: Qt.rgba(0, 0, 0, 0.16)
                    border { width: 1; color: Qt.rgba(1, 1, 1, 0.24) }
                    Icon {
                      anchors.centerIn: parent
                      name: modelData.profile === "lovable-watcher" ? "binoculars" : "users"
                      width: 14; height: 14
                      color: modelData.ask ? Theme.orange : (modelData.status === "streaming" ? Theme.green : "white")
                      Behavior on color { ColorAnimation { duration: 220 } }
                    }
                    HoverHandler { id: subagentHover; cursorShape: Qt.PointingHandCursor }
                    HoverTip {
                      objectName: "subagentTooltip"
                      parent: root
                      shown: subagentHover.hovered
                      text: modelData.name + " · " + (modelData.ask ? "needs input" : modelData.status)
                      z: 100
                      x: {
                        view.contentY; sessionCard.x; subagentIndicator.x
                        return Math.max(8, Math.min(root.width - width - 8, subagentIndicator.mapToItem(root, subagentIndicator.width / 2, 0).x - width / 2))
                      }
                      y: {
                        view.contentY; sessionCard.y; meshPanel.y
                        return subagentIndicator.mapToItem(root, 0, 0).y - height - (shown ? 8 : 3)
                      }
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.sessionRequested(modelData.name) }
                  }
                }
              }
              Column {
                id: sessionDetails
                anchors { left: insetBox.left; right: insetBox.right; bottom: insetBox.bottom; bottomMargin: 44 }
                spacing: 16
                TicketSummary {
                  id: ticketBadges
                  objectName: "ticketBadges"
                  enabled: !sessionCard.expanded
                  width: parent.width
                  ticket: sessionCard.ticket
                  }
                Item {
                  width: parent.width
                  height: 84
                  Text {
                    id: description
                    width: parent.width
                    maximumLineCount: actionStatus.visible ? 2 : 4
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignTop
                    text: root.summary(sessionCard.modelData)
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignLeft
                    color: Theme.fg
                    opacity: 0.72
                    lineHeight: 1.15
                    font { family: "Inter"; pixelSize: 15 }
                  }
                  Text {
                    id: actionStatus
                    objectName: "ticketActionStatus"
                    readonly property string message: sessionCard.reapState !== "" && sessionCard.reapLine ? sessionCard.reapLine : sessionCard.actionMessage
                    visible: message.length > 0
                    anchors.bottom: parent.bottom
                    width: parent.width
                    text: message; textFormat: Text.PlainText
                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                    color: sessionCard.actionError || sessionCard.reapState === "failed" ? Theme.red : root.muted
                    font { family: "Inter"; pixelSize: 13 }
                  }
                }
              }
            }
            Rectangle {
              objectName: "veilScrim"
              anchors { fill: parent; margins: 1 }
              radius: sessionCard.radius - 1
              color: sessionCard.faceMid
              opacity: 0.9 * sessionCard.veil
              visible: opacity > 0
            }
            Item {
              id: question
              objectName: "ticketQuestion"
              z: 1
              anchors { left: sessionInset.left; right: sessionInset.right; top: sessionInset.top; bottom: sessionInset.bottom; bottomMargin: 44 }
              opacity: sessionCard.askReveal
              visible: opacity > 0
              enabled: sessionCard.asking
              Flickable {
                id: questionScroll
                objectName: "questionScroll"
                anchors { fill: parent; bottomMargin: choices.height + (choices.height ? 12 : 0) + (waiting.visible ? waiting.height + 8 : 0) }
                clip: true
                contentWidth: width
                contentHeight: questionText.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                function scrollBy(px) { contentY = Math.max(0, Math.min(contentHeight - height, contentY + px)) }
                WheelHandler {
                  target: null
                  acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                  onWheel: e => {
                    questionScroll.scrollBy(-(point.device.type === PointerDevice.TouchPad ? e.angleDelta.y * 1.2 : (e.pixelDelta.y || e.angleDelta.y / 8) * 5))
                    e.accepted = true
                  }
                }
                Column {
                  id: questionText
                  width: parent.width - 12
                  spacing: 12
                  Text {
                    objectName: "questionTitle"
                    width: parent.width
                    text: sessionCard.ask ? sessionCard.ask.title || "Question" : ""
                    textFormat: Text.PlainText; wrapMode: Text.Wrap
                    color: Theme.fg
                    font { family: "Inter"; pixelSize: 17; weight: 600 }
                  }
                  Text {
                    objectName: "questionBody"
                    width: parent.width
                    visible: text.length > 0
                    text: sessionCard.ask ? sessionCard.ask.message || sessionCard.ask.placeholder || "" : ""
                    textFormat: Text.PlainText; wrapMode: Text.Wrap
                    color: Theme.fg
                    opacity: 0.82
                    lineHeight: 1.25
                    font { family: "Inter"; pixelSize: 14 }
                  }
                }
              }
              Rectangle {
                objectName: "questionScrollbar"
                visible: questionScroll.contentHeight > questionScroll.height
                anchors.right: parent.right
                width: 3; radius: 1.5; opacity: 0.5
                color: root.muted
                height: Math.max(24, questionScroll.height * questionScroll.height / Math.max(1, questionScroll.contentHeight))
                y: (questionScroll.height - height) * Math.max(0, Math.min(1, questionScroll.contentY / Math.max(1, questionScroll.contentHeight - questionScroll.height)))
              }
              Column {
                id: choices
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: waiting.visible ? waiting.height + 8 : 0 }
                spacing: 8
                Repeater {
                  model: sessionCard.ask && sessionCard.ask.method === "select" ? sessionCard.answers : []
                  delegate: Rectangle {
                    required property var modelData
                    objectName: "answerOption"
                    width: choices.width; height: 36; radius: 8
                    enabled: !sessionCard.answerSending
                    opacity: enabled ? 1 : 0.45
                    color: optionHover.hovered ? Theme.hairline : "transparent"
                    border { width: 1; color: Theme.hairline }
                    Text {
                      anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                      verticalAlignment: Text.AlignVCenter
                      text: modelData.label; textFormat: Text.PlainText; elide: Text.ElideRight
                      color: Theme.fg
                      font { family: "Inter"; pixelSize: 13; weight: 600 }
                    }
                    HoverHandler { id: optionHover; cursorShape: Qt.PointingHandCursor }
                    MouseArea { anchors.fill: parent; onClicked: sessionCard.answer(modelData) }
                  }
                }
              }
              Text {
                id: waiting
                anchors.bottom: parent.bottom
                visible: sessionCard.answerSending
                text: "Waiting for confirmation\u2026"
                color: root.muted
                font { family: "Inter"; pixelSize: 12 }
              }
            }
            Flickable {
              id: expandedContent
              objectName: "expandedContent"
              z: 1
              anchors { left: sessionInset.left; right: sessionInset.right; top: sessionInset.top; bottom: sessionInset.bottom; bottomMargin: 44 }
              opacity: sessionCard.reveal
              visible: opacity > 0
              enabled: sessionCard.expanded
              clip: true
              contentWidth: width
              contentHeight: expandedColumn.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              WheelHandler {
                target: null
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: e => {
                  sessionCard.scrollBy(-(point.device.type === PointerDevice.TouchPad ? e.angleDelta.y * 1.2 : (e.pixelDelta.y || e.angleDelta.y / 8) * 5))
                  e.accepted = true
                }
              }
              Column {
                id: expandedColumn
                width: expandedContent.width - (expandedContent.contentHeight > expandedContent.height ? 12 : 0)
                spacing: 16
                TicketSummary { width: parent.width; ticket: sessionCard.ticket; limit: 2147483647 }
                Text {
                  objectName: "expandedDescription"
                  width: parent.width
                  text: root.summary(sessionCard.modelData)
                  textFormat: Text.PlainText; wrapMode: Text.Wrap
                  color: Theme.fg; opacity: 0.72; lineHeight: 1.15
                  font { family: "Inter"; pixelSize: 15 }
                }
                  Rectangle {
                    id: statusDetails
                    objectName: "ticketStatusDetails"
                    visible: !!sessionCard.ticket.details
                    width: parent.width
                    implicitHeight: facts.implicitHeight + 24
                    height: visible ? implicitHeight : 0
                    radius: 10
                    color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.025)
                    border { width: 1; color: Theme.hairline }
                    Column {
                      id: facts
                      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                      spacing: 9
                      Text {
                        text: "DETAILS"
                        color: root.muted
                        font { family: Theme.fontFamily; pixelSize: 10; weight: 600; letterSpacing: 1.2 }
                      }
                      Repeater {
                        model: root.detailRows(sessionCard.ticket.details)
                        delegate: Row {
                          required property var modelData
                          width: facts.width; spacing: 10
                          Text {
                            width: 104
                            text: modelData.label; textFormat: Text.PlainText; elide: Text.ElideRight
                            color: root.muted
                            font { family: Theme.fontFamily; pixelSize: 11 }
                          }
                          Text {
                            width: parent.width - 114
                            text: modelData.value; textFormat: Text.PlainText; wrapMode: Text.Wrap
                            color: Theme.fg
                            font { family: Theme.fontFamily; pixelSize: 12 }
                          }
                        }
                      }
                    }
                  }
              }
            }
            Rectangle {
              objectName: "expandedScrollbar"
              z: 2
              visible: expandedContent.visible && expandedContent.contentHeight > expandedContent.height
              opacity: sessionCard.reveal * 0.5
              anchors.right: expandedContent.right
              width: 3; radius: 1.5
              color: root.muted
              height: Math.max(24, expandedContent.height * expandedContent.height / Math.max(1, expandedContent.contentHeight))
              y: expandedContent.y + (expandedContent.height - height) * Math.max(0, Math.min(1, expandedContent.contentY / Math.max(1, expandedContent.contentHeight - expandedContent.height)))
            }
            Row {
              anchors { right: sessionInset.right; bottom: sessionInset.bottom }
              z: 3
              height: 28
              spacing: 8
              Repeater {
                model: sessionCard.asking && sessionCard.ask.method !== "select" ? sessionCard.answers : []
                delegate: Rectangle {
                  required property var modelData
                  readonly property bool primary: !!(modelData.response && modelData.response.confirmed)
                  objectName: modelData.response ? (modelData.response.confirmed ? "answerYes" : "answerNo") : "answerOption"
                  width: answerRow.implicitWidth + 20; height: 28; radius: 7
                  enabled: !sessionCard.answerSending
                  opacity: (enabled ? 1 : 0.45) * sessionCard.askReveal
                  color: primary ? Theme.fg : (answerHover.hovered ? Theme.hairline : "transparent")
                  border { width: primary ? 0 : 1; color: Theme.hairline }
                  Row {
                    id: answerRow
                    anchors.centerIn: parent
                    spacing: 6
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.label; textFormat: Text.PlainText
                      color: primary ? Theme.bg : Theme.fg
                      font { family: Theme.fontFamily; pixelSize: 13; weight: primary ? 600 : 400 }
                    }
                    KeyCap {
                      visible: !!modelData.key
                      anchors.verticalCenter: parent.verticalCenter
                      text: (modelData.key || "").toLowerCase(); small: true; ghost: primary
                      textColor: primary ? Theme.bg : root.muted
                    }
                  }
                  HoverHandler { id: answerHover; cursorShape: Qt.PointingHandCursor }
                  MouseArea { anchors.fill: parent; onClicked: sessionCard.answer(modelData) }
                }
              }
              Rectangle {
                id: actionButton
                objectName: "ticketAction"
                readonly property real room: {
                  var w = sessionInset.width
                  for (var i = 0; i < sessionButtons.count; i++) {
                    var b = sessionButtons.itemAt(i)
                    if (b && b.visible) w -= b.width + 8
                  }
                  return w
                }
                visible: sessionCard.action.length > 0 && !sessionCard.asking
                enabled: visible && !sessionCard.reaping
                opacity: enabled ? 1 : 0.5
                width: Math.min(actionLabel.implicitWidth + 20, room); height: 28; radius: 7
                readonly property color tint: sessionCard.action === "reap" ? Theme.red : Theme.fg
                color: sessionCard.actionArmed ? tint : (actionHover.hovered ? Theme.hairline : "transparent")
                border { width: 1; color: sessionCard.actionArmed ? tint : Theme.hairline }
                Behavior on color { ColorAnimation { duration: 160 } }
                Row {
                  id: actionLabel
                  anchors.centerIn: parent
                  spacing: 6
                Text {
                  id: actionText
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, actionButton.room - 20 - (actionKey.visible ? actionKey.width + actionLabel.spacing : 0))
                  elide: Text.ElideRight
                  text: sessionCard.reaping ? "Reaping\u2026" : sessionCard.reapState === "failed" && !sessionCard.actionArmed ? "Retry reap" : (sessionCard.actionArmed ? "Confirm " : "") + (sessionCard.action === "reap" ? (sessionCard.actionArmed ? "reap" : "Reap")
                    : sessionCard.action === "claude-review" ? (sessionCard.actionArmed ? "review" : "Claude review")
                    : (sessionCard.actionArmed ? "sync" : "Sync heads"))
                  color: sessionCard.actionArmed ? Theme.bg : (sessionCard.action === "reap" ? Theme.red : Theme.fg)
                  font { family: Theme.fontFamily; pixelSize: 13 }
                }
                KeyCap {
                  id: actionKey
                  visible: sessionCard.action === "reap" && !sessionCard.reaping
                  anchors.verticalCenter: parent.verticalCenter
                  text: "d"; small: true; ghost: sessionCard.actionArmed
                  textColor: sessionCard.actionArmed ? Theme.bg : root.muted
                }
                }
                HoverHandler { id: actionHover; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: sessionCard.runAction() }
              }
              Repeater {
                id: sessionButtons
                model: ["expand", "open"]
                delegate: Rectangle {
                  required property string modelData
                  objectName: modelData + "Session"
                  visible: sessionCard.asking ? modelData === "open" && sessionCard.ask.method === "select" : modelData === "open" || sessionCard.canExpand
                  enabled: visible
                  width: buttonText.implicitWidth + 20
                  height: 28
                  radius: 7
                  color: buttonHover.hovered ? Theme.hairline : "transparent"
                  border.width: 1; border.color: Theme.hairline
                  Text {
                    id: buttonText
                    anchors.centerIn: parent
                    text: modelData === "open" ? "Open" : (sessionCard.expanded ? "Collapse" : "Expand")
                    color: root.muted
                    font { family: Theme.fontFamily; pixelSize: 13 }
                  }
                  HoverHandler { id: buttonHover; cursorShape: Qt.PointingHandCursor }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.cursor = root.selectable.indexOf("session:" + sessionCard.modelData)
                      root.forceActiveFocus()
                      if (modelData === "expand") root.toggleCard(sessionCard.modelData)
                      else root.dispatch("session:" + sessionCard.modelData)
                    }
                  }
                }
              }
            }
          }
        }
      }
      Text {
        visible: root.showSessions && !root.workers.length
        anchors.horizontalCenter: parent.horizontalCenter
        text: "No open sessions"
        color: root.muted
        font { family: Theme.fontFamily; pixelSize: 16 }
      }

      Repeater {
        model: root.showSessions ? [] : (root.model.cards || [])
        delegate: Card {
          id: card
          required property var modelData
          width: content.width
          height: cardBody.implicitHeight + 42

          Column {
            id: cardBody
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
            spacing: 4

            Text {
              text: (root.model.tabs || []).length
                ? String(root.model.activeTab || modelData.title || "").toUpperCase()
                : String(modelData.title || "")
              color: Theme.fg
              font { family: Theme.fontFamily; pixelSize: 16; weight: 650 }
              bottomPadding: 8
            }

            Flickable {
              id: rowsView
              width: cardBody.width
              height: Math.min(rowsColumn.implicitHeight, 548)
              contentWidth: width
              contentHeight: rowsColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollFeel { flick: rowsView }

              Column {
                id: rowsColumn
                width: rowsView.width
                spacing: 4

                Repeater {
                  id: rows
                  model: card.modelData.rows || []
                  delegate: Rectangle {
                id: row
                required property var modelData
                objectName: modelData.action ? "dashRow:" + modelData.action : ""
                width: cardBody.width
                height: modelData.text ? 32 : 12
                radius: 8
                color: root.activeFocus && modelData.action === root.currentAction ? Theme.itemCursor : "transparent"

                readonly property bool splitMarker: !!modelData.markerTone && String(modelData.text || "").length > 1
                readonly property bool hasIcon: modelData.icon !== undefined || splitMarker
                readonly property var change: modelData.additions !== undefined
                  ? ({ label: String(modelData.label || ""), additions: String(modelData.additions), removals: String(modelData.removals) })
                  : root.changeParts(modelData.text)
                readonly property bool hasAdditions: !!change && change.additions !== "+0"
                readonly property bool hasRemovals: !!change && change.removals !== "-0"

                Icon {
                  id: marker
                  anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                  visible: row.hasIcon
                  width: 18
                  height: 18
                  name: row.modelData.icon !== undefined ? String(row.modelData.icon)
                    : row.change ? "file-content"
                    : row.modelData.markerTone === "success" ? "check"
                    : row.modelData.markerTone === "accent" ? "loader"
                    : row.modelData.markerTone === "error" ? "triangle-warning"
                    : "minus"
                  color: row.change
                    ? (row.hasAdditions && row.hasRemovals ? Theme.yellow
                      : row.hasAdditions ? Theme.green : Theme.red)
                    : root.tone(row.modelData.iconTone || row.modelData.markerTone)
                }
                // Inline leading glyphs (nerd-font chars baked into row text — ▤, ◁,
                // ticket marks) render as their own run so icons can outsize text.
                readonly property string rawText: change ? "" : (modelData.label !== undefined
                    ? String(modelData.label)
                    : (splitMarker ? String(modelData.text || "").slice(1).trim() : String(modelData.text || "")))
                readonly property int _lead: rawText.length ? rawText.charCodeAt(0) : 0
                readonly property bool inlineGlyph: !hasIcon && !change
                    && ((_lead >= 0x2190 && _lead <= 0x2BFF)
                     || (_lead >= 0xE000 && _lead <= 0xF8FF)
                     || (_lead >= 0xD800 && _lead <= 0xDBFF))
                readonly property int glyphLen: (_lead >= 0xD800 && _lead <= 0xDBFF) ? 2 : 1
                Text {
                  id: leadGlyph
                  visible: row.inlineGlyph
                  anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                  text: visible ? row.rawText.slice(0, row.glyphLen) : ""
                  color: root.tone(row.modelData.tone)
                  font { family: Theme.fontFamily; pixelSize: 18 }
                }
                Text {
                  anchors {
                    left: row.hasIcon ? marker.right : (row.inlineGlyph ? leadGlyph.right : parent.left)
                    leftMargin: row.hasIcon || row.inlineGlyph ? 7 : 10
                    right: stats.visible ? stats.left : parent.right
                    rightMargin: stats.visible ? 18 : 10
                    verticalCenter: parent.verticalCenter
                  }
                  text: row.inlineGlyph
                    ? row.rawText.slice(row.glyphLen).replace(/^\s+/, "")
                    : (row.change ? row.change.label : row.rawText)
                  color: root.tone(row.modelData.tone)
                  elide: Text.ElideMiddle
                  font { family: Theme.fontFamily; pixelSize: 15 }
                }
                Row {
                  id: stats
                  anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                  visible: !!row.change || row.modelData.detail !== undefined
                  spacing: 14
                  Text {
                    visible: !!row.change
                    text: row.change ? row.change.additions : ""
                    color: row.hasAdditions ? Theme.green : root.muted
                    font { family: Theme.fontFamily; pixelSize: 15; weight: 650 }
                  }
                  Text {
                    visible: !!row.change
                    text: row.change ? row.change.removals : ""
                    color: row.hasRemovals ? Theme.red : root.muted
                    font { family: Theme.fontFamily; pixelSize: 15; weight: 650 }
                  }
                  Text {
                    visible: row.modelData.detail !== undefined
                    text: visible ? String(row.modelData.detail) : ""
                    color: root.muted
                    font { family: Theme.fontFamily; pixelSize: 15; weight: 600 }
                  }
                }
                TapHandler {
                  enabled: !!row.modelData.action
                  onTapped: {
                    root.cursor = Math.max(0, root.selectable.indexOf(row.modelData.action))
                    root.dispatch(row.modelData.action)
                  }
                }
              }
            }
          }

              Connections {
                target: root
                function onCurrentActionChanged() {
                  for (var i = 0; i < rows.count; i++) {
                    var item = rows.itemAt(i)
                    if (!item || item.modelData.action !== root.currentAction) continue
                    if (item.y < rowsView.contentY) rowsView.contentY = item.y
                    else if (item.y + item.height > rowsView.contentY + rowsView.height)
                      rowsView.contentY = item.y + item.height - rowsView.height
                    return
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Item {
    id: hints
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    visible: root.visibleActions.length > 0
    height: visible ? 40 : 0
    Row {
      anchors.centerIn: parent
      spacing: 18
      Repeater {
        model: root.visibleActions
        delegate: Row {
          required property var modelData
          spacing: 7
          KeyCap { text: modelData.key; small: true }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label
            color: root.muted
            font { family: Theme.fontFamily; pixelSize: 14 }
          }
          TapHandler { onTapped: root.dispatch(modelData.id) }
        }
      }
    }
  }

  Image {
    anchors { right: parent.right; bottom: parent.bottom; margins: 16 }
    visible: root.model.masthead !== "lovable"
    height: 44
    width: height * 248 / 308
    source: visible ? root.assetUrl("cockpit-mark-" + Theme.mode + ".png") : ""
    sourceSize.height: height * 2
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
  }

  Rectangle {
    id: dashRestDot
    objectName: "dashRestDot"
    z: 5
    width: 8; height: 8; radius: 4
    color: Theme.cursor
    visible: !!root.restPoint && !root.caretHeld && root.restPoint.y > view.y && root.restPoint.y < view.y + view.height
    x: root.restPoint ? root.restPoint.x - width / 2 : 0
    y: root.restPoint ? root.restPoint.y - height / 2 : 0
    Behavior on x { enabled: dashRestDot.visible; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on y { enabled: dashRestDot.visible; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
  }
}
