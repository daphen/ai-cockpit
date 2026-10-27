import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import QsLib
import QtTest
import "rail"

ShellRoot {
  id: app
  property string sample: "Conversation"
  property string notice: "Isolated samples · no live agents"
  property int generation: 0
  property string sid: ""
  property var entries: []
  property int streamIndex: 0
  readonly property string streamText: "The response streams into the real rail. Tool calls remain available, and this sample lets us check wrapping, scrolling, and selection as the message grows. ".repeat(8)
  readonly property bool checking: Quickshell.env("COCKPIT_PRESENTATION_CHECK") === "1"

  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function add(role, content, extra) {
    var message = Object.assign({role: role, content: content}, extra || {})
    if (role === "assistant") message.model = "openai/gpt-6.1-sol"
    var id = sid + "-" + entries.length
    entries.push({type: "message", id: id, parentId: entries.length ? entries[entries.length - 1].id : null, message: message})
  }
  function text(value) { return [{type: "text", text: value}] }
  function addQuestion() {
    add("assistant", [{type: "text", text: "The change is ready for review."},
      {type: "toolCall", id: "approval-" + generation, name: "ask_user", arguments: {kind: "confirm", title: "Apply the presentation change?", message: "Only this mock window will change."}}])
  }
  function requestQuestion() {
    event({type: "extension_ui_request", session: sid, id: "approval-" + generation,
      method: "confirm", title: "Apply the presentation change?", message: "Only this mock window will change."})
  }
  function askWhileTyping() {
    load("Conversation")
    preview.enterInsert()
    deferredQuestion.restart()
    notice = "Keep typing · a mock question arrives in one second"
  }
  function history() {
    event({type: "response", command: "get_entries", session: sid, success: true,
      data: {entries: entries, leafId: entries.length ? entries[entries.length - 1].id : null}})
  }
  function load(name) {
    stream.stop(); deferredQuestion.stop()
    sample = name; generation++; sid = "preview-" + generation; entries = []
    var home = Quickshell.env("HOME")
    event({type: "roster", sessions: [{id: sid, name: sid, cwd: home, plan: "mobile-optimistic-messages", status: "idle", profile: "coding", scope: "personal"},
      {id: "every-4032", name: "every-4032", cwd: home, plan: "every-4032-stream-reveal", status: "streaming", profile: "coding", scope: "personal"},
      {id: "chromium-palette", name: "chromium-palette", cwd: home, plan: "palette-contrast-pass", status: "idle", profile: "coding", scope: "personal"},
      {id: "nixos", name: "nixos", cwd: home, status: "idle", profile: "coding", scope: "personal"},
      {id: "quickshell", name: "quickshell", cwd: home, status: "asleep", profile: "coding", scope: "personal"}]})
    preview.jumpToSession(sid)
    if (name === "Subagents") {
      add("user", text("Compare the candidates and report the useful result."))
      add("user", text("⇄ layout-worker (user-approved)\nThe candidate build passed. The patch changes three files, and the baseline is unchanged. Performance testing still needs an approved capture window.\n\nDetailed evidence\n\n" + "The log records the exact build command, source revision, and result. ".repeat(18)))
      add("assistant", text("The candidate is ready for testing, but there is no measured performance result yet."))
    } else if (name === "Markdown") {
      add("user", text("Show the typography and inline references together."))
      add("assistant", text("## A readable result\n\n**The build passed.** This paragraph tests **bold**, *italic*, and a [normal link](https://example.com).\n\n- First list item\n- Second item with a nested list\n  - Nested detail\n\n1. Prepare the sample.\n2. Check the result.\n\n> A quote should be distinct without looking like a user message.\n\nThe file `Rail.qml` and the command `git diff --check` should not break Markdown.\n\n```sh\nprintf 'hello\\n'\n```"))
    } else if (name === "Approval") {
      add("user", text("Fix the layout without restarting my Cockpit."))
      addQuestion()
    } else {
      add("user", text("Keep the tool calls visible and show me the useful outcome."))
      add("assistant", [{type: "text", text: "I’ll inspect the layout and run the focused checks."},
        {type: "toolCall", id: "read-" + generation, name: "read", arguments: {path: "Rail.qml"}},
        {type: "toolCall", id: "edit-" + generation, name: "edit", arguments: {path: "Rail.qml", edits: [{oldText: "old layout", newText: "new layout"}]}},
        {type: "toolCall", id: "bash-" + generation, name: "bash", arguments: {command: "printf 'render checks passed\\n'\ngit diff --check"}}])
      add("toolResult", text("All focused checks passed."), {toolCallId: "bash-" + generation, toolName: "bash", isError: false})
      add("assistant", text("**The layout checks passed.**\n\nTool calls are visible, full commands can be expanded, and the response remains readable."))
      add("user", text("Keep the scope to presentation changes."), {steered: true})
    }
    history()
    if (name === "Approval") requestQuestion()
    preview.exitInsert()
    notice = name + " sample · mock only"
  }
  function beginStream() {
    streamIndex = 0
    event({type: "agent_start", session: sid})
    event({type: "message_start", session: sid, message: {role: "assistant"}})
    stream.start()
    notice = "Streaming sample · mock only"
  }

  AgentdState {
    id: state
    configuredSockPaths: []
    selectedSession: preview.selectedRaw
    Component.onCompleted: connected = true
    function _rebuildSessions() {
      sessions = (_rosters[0] || []).map(session => Object.assign({}, session, {scope: "personal", offline: false}))
      gen++; settled = true
    }
    function send(message) {
      if (message.type === "answer") Qt.callLater(function() {
        var response = message.response
        var accepted = response.confirmed === true || response.value === "approved"
        app.event({type: "ask_answered", session: app.sid, id: "approval-" + app.generation, confirmed: accepted})
        app.add("toolResult", app.text(JSON.stringify({confirmed: accepted})), {toolCallId: "approval-" + app.generation, toolName: "ask_user"})
        app.history()
        app.notice = "Mock approval answered; no external action taken"
      })
      else if (message.type === "prompt" || message.type === "steer") Qt.callLater(function() {
        app.event({type: "prompt_accepted", session: app.sid, message: message.message, steered: message.type === "steer"})
        app.add("user", app.text(message.message), {steered: message.type === "steer"})
        app.add("assistant", app.text("This is a mock response. Nothing was sent to a live agent."))
        app.history()
      })
      return true
    }
  }
  Timer {
    id: deferredQuestion
    interval: 1000
    onTriggered: { app.addQuestion(); app.history(); app.requestQuestion(); app.notice = "Your draft keeps focus · click the question to answer" }
  }
  Timer {
    id: stream
    interval: 35; repeat: true
    onTriggered: {
      var delta = app.streamText.slice(app.streamIndex, app.streamIndex + 14)
      app.streamIndex += delta.length
      app.event({type: "message_update", session: app.sid, assistantMessageEvent: {type: "text_delta", delta: delta}})
      if (app.streamIndex >= app.streamText.length) {
        stop()
        app.event({type: "message_end", session: app.sid, message: {role: "assistant", content: app.text(app.streamText)}})
        app.add("assistant", app.text(app.streamText)); app.history()
        app.event({type: "agent_end", session: app.sid})
        app.notice = "Streaming finished · Replay resets the sample"
      }
    }
  }
  FloatingWindow {
    id: window
    title: "Cockpit Rail · Presentation"
    visible: true; implicitWidth: 820; implicitHeight: 1040
    color: Theme.mode === "dark" ? Qt.tint(Theme.bgDim, Qt.alpha(Theme.fg, 0.03)) : Theme.bgDim
    ColumnLayout {
      id: page
      anchors.fill: parent; anchors.margins: 12; spacing: 8
      RowLayout {
        Layout.fillWidth: true
        Text { text: "RAIL PRESENTATION"; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: 14; font.bold: true }
        Item { Layout.fillWidth: true }
        PrimaryButton { text: "Replay"; primary: false; onClicked: app.load(app.sample) }
        PrimaryButton { text: stream.running ? "Streaming…" : "Stream"; primary: false; enabled: !stream.running; onClicked: app.beginStream() }
        PrimaryButton { text: "While typing"; primary: false; onClicked: app.askWhileTyping() }
        PrimaryButton { text: "Close"; primary: false; onClicked: Qt.quit() }
      }
      RowLayout {
        Layout.fillWidth: true
        Repeater {
          model: ["Conversation", "Markdown", "Subagents", "Approval"]
          PrimaryButton { required property string modelData; text: modelData; primary: app.sample === modelData; Layout.fillWidth: true; onClicked: app.load(modelData) }
        }
      }
      Text { text: app.notice; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 13 }
      Rail {
        id: preview
        TestEvent { id: input }
        Layout.fillWidth: true; Layout.fillHeight: true
        agentd: state; scopeMode: "personal"; instanceName: "rail-presentation"; focused: true
        onRequestFocus: forceActiveFocus()
        onRequestScopeMode: app.notice = "The preview has no live scopes"
        function openInNvim(path, baseCwd, line, column) { app.notice = "Mock file action: " + path }
        function openFileRef(ref) { app.notice = "Mock file action: " + ref.path }
        function openNew() { app.notice = "Session creation is disabled in the preview" }
        function runLifecycle(action) { app.notice = "Session lifecycle actions are disabled in the preview" }
        function openPlanBinding() { app.notice = "Plan actions are disabled in the preview" }
        function pasteImage() { app.notice = "Use the sample fixtures for images in this preview" }
      }
    }
  }
  Component.onCompleted: Qt.callLater(function() { app.load("Conversation") })
  Timer {
    property int phase: 0
    property real lastCardHeight: 0
    property int heightFrames: 0
    property bool blended: false
    property int motionTicks: 0
    interval: 350; repeat: true; running: app.checking
    onTriggered: {
      function findLabel(item, text) {
        if (!item || item.visible === false) return null
        if (item.text === text) return item
        for (var child of item.children || []) {
          var found = findLabel(child, text)
          if (found) return found
        }
        return null
      }
      function visibleOpacity(item) {
        var alpha = 1
        while (item) { if (item.opacity !== undefined) alpha *= item.opacity; item = item.parent }
        return alpha
      }
      if (phase === 4 || phase === 8) {
        var title = findLabel(preview, "Apply the presentation change?")
        if (!title) throw new Error("Question disappeared during animation")
        var height = title.parent.parent.parent.height
        if (Math.abs(height - lastCardHeight) > 0.25) { heightFrames++; lastCardHeight = height }
        var firstAlpha = visibleOpacity(findLabel(preview, "Approve"))
        var secondAlpha = visibleOpacity(findLabel(preview, "YOUR ANSWER"))
        if (firstAlpha > 0.01 && firstAlpha < 0.99 && secondAlpha > 0.01 && secondAlpha < 0.99) blended = true
        if (++motionTicks < 36) return
        if (heightFrames < 3) throw new Error("Question height did not animate through intermediate frames")
        if (!blended) throw new Error("Question content did not crossfade")
        interval = 350
      }
      if (state.sockPaths.length !== 0 || !preview.groupedFeed.length) throw new Error("Preview is connected or has no fixture rows")
      if (state.sessions.length !== 1 || preview.featured.rawName !== app.sid) throw new Error("Mock session is missing from the composer")
      if (phase === 0) app.load("Markdown")
      else if (phase === 1) app.load("Subagents")
      else if (phase === 2) app.load("Approval")
      else if (phase === 3) {
        if (!state.asks[app.sid]) throw new Error("Mock approval not visible")
        var button = findLabel(preview, "Approve")
        if (!button) throw new Error("Question approval button not in the chat")
        lastCardHeight = findLabel(preview, "Apply the presentation change?").parent.parent.parent.height
        heightFrames = 0; blended = false; motionTicks = 0; interval = 16
        input.mouseClick(button, 5, button.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
      } else if (phase === 4) {
        if (state.asks[app.sid]) throw new Error("Mock approval did not resolve")
        var rows = preview.groupedFeed
        if (rows.filter(row => row.kind === "question" && row.answer === "approved").length !== 1) throw new Error("Answer not attached to its question")
        if (rows.filter(row => row.kind === "user").length !== 1) throw new Error("Answer became a separate user message")
        if (!findLabel(preview, "YOUR ANSWER")) throw new Error("Attached answer not rendered")
        app.load("Conversation"); app.beginStream()
      } else if (phase === 5) {
        if (app.streamIndex === 0) throw new Error("Mock stream did not advance")
        if (stream.running) return
        if (state.feedFor(app.sid).filter(item => item.kind === "text" && item.text.trim() === app.streamText.trim()).length !== 1) throw new Error("Completed stream is duplicated")
        state.sendPrompt(app.sid, "Mock composer message")
      } else if (phase === 6) {
        if (!state.feedFor(app.sid).some(item => item.kind === "text" && item.text.indexOf("Nothing was sent") >= 0)) throw new Error("Mock composer did not receive a local reply")
        app.load("Approval")
      } else if (phase === 7) {
        var decline = findLabel(preview, "Decline")
        if (!decline) throw new Error("Question decline button missing")
        lastCardHeight = findLabel(preview, "Apply the presentation change?").parent.parent.parent.height
        heightFrames = 0; blended = false; motionTicks = 0; interval = 16
        input.mouseClick(decline, 5, decline.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
      } else if (phase === 8) {
        if (preview.groupedFeed.filter(row => row.kind === "question" && row.answer === "declined").length !== 1) throw new Error("Decline not attached to its question")
        if (preview.groupedFeed.filter(row => row.kind === "user").length !== 1) throw new Error("Decline became a separate user message")
        if (state.staleAskFor(app.sid)) throw new Error("Answered question still shown as pending")
        stop()
        preview.grabToImage(function(result) {
          if (!result.saveToFile(Quickshell.env("XDG_RUNTIME_DIR") + "/answered-question.png")) throw new Error("Question frame capture failed")
          start()
        })
      } else if (phase === 9) {
        var typing = findLabel(page, "While typing")
        input.mouseClick(typing, 5, typing.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
      } else if (phase === 10) {
        input.keyClick(Qt.Key_Y, Qt.NoModifier, 0)
        input.keyClick(Qt.Key_N, Qt.NoModifier, 0)
        input.keyClick(Qt.Key_1, Qt.NoModifier, 0)
        input.keyClick(Qt.Key_2, Qt.NoModifier, 0)
      } else if (phase === 11) {
        if (!state.asks[app.sid]) return
        if (!preview.insert || !preview.askDeferred || preview.composerText !== "yn12") throw new Error("Question stole the composer or changed the draft")
        input.keyClick(Qt.Key_Return, Qt.NoModifier, 0)
      } else if (phase === 12) {
        if (!state.asks[app.sid] || preview.composerText.length) throw new Error("Enter answered the question instead of sending the draft")
        input.keyClick(Qt.Key_Y, Qt.NoModifier, 0)
        if (preview.composerText !== "y") throw new Error("Composer no longer accepts typing")
        input.keyClick(Qt.Key_Escape, Qt.NoModifier, 0)
        input.keyClick(Qt.Key_Y, Qt.NoModifier, 0)
        if (!state.asks[app.sid] || !preview.askDeferred) throw new Error("Leaving the composer activated a question accidentally")
        input.keyClick(Qt.Key_Escape, Qt.NoModifier, 0)
        var explicit = findLabel(preview, "Approve")
        input.mouseClick(explicit, 5, explicit.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
      } else if (phase === 13) {
        if (state.asks[app.sid]) throw new Error("Explicit question click did not answer")
        console.log("PASS: question height animates and content crossfades; answers stay attached; typing and draft Enter never answer; completed stream appears once; no agent sockets")
        Qt.quit()
      }
      phase++
    }
  }
}
