import QtQuick
import Quickshell
import Quickshell.Io

// Client for agentd's unix socket ($XDG_RUNTIME_DIR/agentd-<scope>.sock).
// On connect the daemon pushes {type:"roster",sessions:[...]}; it also streams
// per-session events (message_*/turn_*/agent_*) — feed wiring comes next.
// Commands go back as one-line JSON: {type:"prompt",session,text} (human, no `from`).
Item {
  id: root

  property string scope: "lovable"
  property bool connected: false
  property var sessions: []      // raw session structs from the daemon
  property int gen: 0            // bumped on every roster push

  // Per-session activity feed. `feeds` is mutated in place; `feedGen` bumps so
  // bindings recompute, and feedFor() returns a fresh slice so ListView refreshes.
  property var feeds: ({})
  property int feedGen: 0
  readonly property int feedCap: 200

  // Per-session changed-files (from the daemon's `changes` diff broadcast).
  property var changes: ({})       // sid -> [{path, add, del}]
  property var changesCwd: ({})    // sid -> cwd (to resolve absolute paths)
  property int changesGen: 0
  function changesFor(sid)    { return (changes[sid] || []).slice() }
  function changesCwdFor(sid) { return changesCwd[sid] || "" }

  function send(obj) {
    const s = sockLoader.item
    if (s && s.connected) s.write(JSON.stringify(obj) + "\n")
  }
  function sendPrompt(sid, text) {
    // agentd/pi expect `message`, not `text`.
    send({ type: "prompt", session: sid, message: text })
    _push(sid, { kind: "user", text: text })   // optimistic echo; get_entries refreshes it
  }
  function stop(sid)             { send({ type: "stop", session: sid }) }
  function feedFor(sid)          { return (feeds[sid] || []).slice() }

  function _base(p)  { var s = String(p); var i = s.lastIndexOf("/"); return i >= 0 ? s.slice(i + 1) : s }
  function _rel(p)   { var s = String(p || ""); return s.replace(/^\/home\/daphen\//, "~/") }
  function _clip(s)  { s = String(s || "").replace(/\s+/g, " "); return s.length > 72 ? s.slice(0, 69) + "…" : s }

  // Mirror of the nvim rail's tool_hint: name + the bit that matters. MCP calls
  // become "mcp <server> <tool>" / "mcp <server> search:<x>" — not "bash mcp".
  function toolHint(name, a) {
    a = a || {}
    if (name === "read" || name === "apply_patch") {
      var p = a.path || a.file_path || a.filePath || ""
      return name + (p ? " " + _rel(p) : "")
    }
    if (name === "bash" || name === "shell")       return "bash " + _clip(a.command || a.cmd)
    if (name === "grep" || name === "ripgrep" || name === "search_files") return "grep " + _clip(a.pattern || a.query || a.regex)
    if (name === "glob" || name === "find")        return "glob " + _clip(a.pattern || a.glob || a.query)
    if (name === "list" || name === "ls")          { var d = a.path || a.dir || a.directory || ""; return "ls " + (d ? _rel(d) : "") }
    if (name === "webfetch" || name === "web_fetch" || name === "fetch") return "fetch " + _clip(a.url || a.uri)
    if (name === "websearch" || name === "web_search") return "web " + _clip(a.query || a.q)
    if (name === "mcp") {
      var bits = []
      if (a.server) bits.push(a.server)
      if (a.tool) bits.push(a.tool)
      else if (a.search) bits.push("search:" + a.search)
      return "mcp " + bits.join(" ")
    }
    return name
  }
  function _countDiff(diff) {
    var a = 0, d = 0
    var ls = String(diff).split("\n")
    for (var i = 0; i < ls.length; i++) {
      var c = ls[i].charAt(0)
      if (c === "+") a++; else if (c === "-") d++
    }
    return [a, d]
  }
  // Parse a `git diff --unified=0` into per-file {path, add, del}.
  function _parseChanges(diff) {
    var files = [], cur = null
    var ls = String(diff).split("\n")
    for (var i = 0; i < ls.length; i++) {
      var ln = ls[i]
      if (ln.indexOf("diff --git ") === 0) { cur = { path: "", add: 0, del: 0 }; files.push(cur) }
      else if (cur && ln.indexOf("+++ b/") === 0) { cur.path = ln.slice(6) }
      else if (cur && ln.indexOf("--- a/") === 0 && !cur.path) { cur.path = ln.slice(6) }
      else if (cur) {
        var c = ln.charAt(0)
        if (c === "+" && ln.indexOf("+++") !== 0) cur.add++
        else if (c === "-" && ln.indexOf("---") !== 0) cur.del++
      }
    }
    return files.filter(f => f.path && f.path !== "/dev/null")
  }

  function _push(sid, item) {
    var arr = feeds[sid] || []
    arr.push(item)
    if (arr.length > feedCap) arr = arr.slice(arr.length - feedCap)
    feeds[sid] = arr
    feedGen++
  }

  // Selecting a session: pull its transcript AND its current changed files.
  function select(sid) {
    if (!sid || !String(sid).length) return
    send({ type: "get_entries", session: sid })
    refreshChanges(sid)
  }

  // Populate the files view on demand by running the session's branch diff
  // locally (the roster carries each session's cwd). Works for local worktrees
  // without an agentd round-trip; the turn_end broadcast keeps it fresh after.
  property string _pendingChangesSid: ""
  function refreshChanges(sid) {
    var cwd = ""
    for (var i = 0; i < sessions.length; i++)
      if (sessions[i].id === sid || sessions[i].name === sid) { cwd = sessions[i].cwd; break }
    if (!cwd) return
    _pendingChangesSid = sid
    gitProc.cwdArg = cwd
    gitProc.running = false
    gitProc.running = true
  }
  Process {
    id: gitProc
    property string cwdArg: ""
    command: ["sh", "-c",
      "cd " + JSON.stringify(cwdArg) + " 2>/dev/null && { git diff --no-color --no-ext-diff --unified=0 origin/main 2>/dev/null || git diff --no-color --no-ext-diff --unified=0 HEAD 2>/dev/null; }"]
    stdout: StdioCollector {
      onStreamFinished: {
        var sid = root._pendingChangesSid
        if (sid) { root.changes[sid] = root._parseChanges(this.text); root.changesCwd[sid] = gitProc.cwdArg; root.changesGen++ }
      }
    }
  }

  // Expand an assistant message's content blocks into feed items (mirror of the
  // nvim rail's msg_text): prose (text), collapsed thinking, and tool calls.
  function _expandAssistant(content, items) {
    var c = content || []
    for (var i = 0; i < c.length; i++) {
      var b = c[i]
      if (b.type === "text" && b.text) {
        var txt = String(b.text).replace(/\s*<system-reminder>[\s\S]*?<\/system-reminder>\s*/g, "\n").trim()
        if (txt) items.push({ kind: "text", text: txt })
      } else if (b.type === "thinking") {
        var th = String(b.thinking || b.text || "")
        if (th.replace(/\s/g, "") !== "") {
          var mm = th.match(/\*\*([\s\S]*?)\*\*/) || th.match(/^\s*([^\n]+)/)
          // Keep the full reasoning (`full`) alongside the short header (`text`)
          // so the expanded view can show the entire thought process.
          items.push({ kind: "think",
                       text: (mm ? mm[1] : "thinking").replace(/\s+/g, " ").trim().slice(0, 90),
                       full: th.trim() })
        }
      } else if (b.type === "toolCall" || b.type === "tool_use") {
        var name = b.name || b.tool || "tool"
        var a = b.arguments || b.input || b.args || {}
        if (name === "edit" || name === "write" || name === "create" || name === "str_replace") {
          var p = a.path || a.file_path || a.filePath || ""
          var add = 0, del = 0
          if (name === "write" || name === "create") {
            add = a.content ? String(a.content).split("\n").length : 0
          } else if (a.edits && a.edits.length) {
            for (var ei = 0; ei < a.edits.length; ei++) {
              var ed = a.edits[ei]
              if (ed.newText) add += String(ed.newText).split("\n").length
              if (ed.oldText) del += String(ed.oldText).split("\n").length
            }
          } else {
            if (a.new_string) add += String(a.new_string).split("\n").length
            if (a.old_string) del += String(a.old_string).split("\n").length
          }
          items.push({ kind: "edit", tool: name, file: _base(p), path: p, add: add, del: del })
        } else {
          items.push({ kind: "cmd", tool: name, text: toolHint(name, a),
                       command: (name === "bash" || name === "shell") ? (a.command || a.cmd || "") : "" })
        }
      }
    }
  }

  // Reconstruct the active branch (leaf→root via parentId) into a flat feed.
  function _entriesToFeed(entries, leafId) {
    var byid = {}
    for (var i = 0; i < entries.length; i++) if (entries[i].id) byid[entries[i].id] = entries[i]
    var cur = leafId
    if (!cur && entries.length) cur = entries[entries.length - 1].id
    var chain = [], seen = {}
    while (cur && byid[cur] && !seen[cur]) { seen[cur] = true; chain.push(byid[cur]); cur = byid[cur].parentId }
    // Collect user/assistant messages chronologically, then only format the TAIL —
    // a big transcript (3000+ entries / 7MB) is otherwise multi-second to expand.
    var msgs = []
    for (var j = chain.length - 1; j >= 0; j--) {
      var e = chain[j]
      if (e.type === "message" && e.message && (e.message.role === "user" || e.message.role === "assistant"))
        msgs.push(e.message)
    }
    var CHAT_CAP = 60
    var startIdx = Math.max(0, msgs.length - CHAT_CAP)
    var items = []
    for (var mi = startIdx; mi < msgs.length; mi++) {
      var msg = msgs[mi]
      if (msg.role === "user") {
        var uc = msg.content || [], ut = ""
        for (var k = 0; k < uc.length; k++) if (uc[k].type === "text" && uc[k].text) ut += (ut ? "\n" : "") + uc[k].text
        ut = ut.replace(/\s*<system-reminder>[\s\S]*?<\/system-reminder>\s*/g, "\n").trim()
        if (ut) items.push({ kind: "user", text: ut })
      } else {
        _expandAssistant(msg.content, items)
      }
    }
    return _coalesce(items)
  }

  // Collapse runs of 3+ consecutive same-tool calls into one group item.
  function _coalesce(items) {
    var out = [], i = 0
    while (i < items.length) {
      var it = items[i]
      if (it.kind === "cmd" && it.tool) {
        var j = i
        while (j < items.length && items[j].kind === "cmd" && items[j].tool === it.tool) j++
        if (j - i >= 3) {
          var cmds = []
          for (var k = i; k < j; k++) cmds.push({ text: items[k].text, command: items[k].command || "" })
          out.push({ kind: "group", tool: it.tool, cmds: cmds })
          i = j
          continue
        }
      }
      out.push(it)
      i++
    }
    return out
  }

  function onLine(data) {
    let m
    try { m = JSON.parse(data) } catch (e) { return }
    if (!m) return
    const t = m.type
    if (t === "roster") { root.sessions = m.sessions || []; root.gen++; return }
    if (t === "response" && m.command === "get_entries") { onEntries(m); return }
    const sid = m.session
    if (!sid) return

    if (t === "changes") {
      changes[sid] = _parseChanges(m.diff || "")
      changesCwd[sid] = m.cwd || ""
      changesGen++
      return
    }
    if (t === "tool_execution_start") {
      const tn = m.toolName || ""
      const args = m.args || {}
      if (tn === "edit" || tn === "write" || tn === "create" || tn === "str_replace") {
        _push(sid, { kind: "edit", tool: tn, file: _base(args.path || ""), path: args.path || "",
                     add: 0, del: 0, id: m.toolCallId })
      } else {
        // bash/mcp/grep/read/… → one-line hint; keep raw command for "run from message".
        _push(sid, { kind: "cmd", tool: tn, text: toolHint(tn, args),
                     command: (tn === "bash" || tn === "shell") ? (args.command || args.cmd || "") : "",
                     id: m.toolCallId })
      }
    } else if (t === "tool_execution_end") {
      const det = m.result && m.result.details
      if (det && det.diff) {
        const ad = _countDiff(det.diff)
        var arr = feeds[sid] || []
        for (var i = arr.length - 1; i >= 0; i--) {
          if (arr[i].id === m.toolCallId) { arr[i].add = ad[0]; arr[i].del = ad[1]; break }
        }
        feeds[sid] = arr; feedGen++
      }
    } else if (t === "turn_end" || t === "agent_end") {
      // Turn finished → refresh the authoritative transcript (prose lives here),
      // but only for sessions already loaded (selected) to avoid parsing 7MB
      // transcripts for sessions you're not looking at.
      if (feeds[sid]) select(sid)
    }
    // message_start / message_update ignored — the prose is reconstructed from
    // get_entries below (matches the nvim rail).
  }

  // get_entries response → rebuild the session's feed from the full transcript.
  function onEntries(m) {
    if (!m.data || !m.data.entries) return
    var esid = m.session
    if (!esid) return
    feeds[esid] = _entriesToFeed(m.data.entries, m.data.leafId)
    feedGen++
  }

  // Socket in a Loader so a re-dial gets a fresh object (wedge recovery),
  // same pattern as PaletteState.
  Loader {
    id: sockLoader
    active: true
    sourceComponent: Socket {
      // HEIDR_AGENTD_SOCK lets a lovbox launcher point at a tunneled remote
      // agentd (autossh -L … presents the remote daemon as a local socket),
      // so the rail is transport-agnostic like the nvim thin client.
      path: Quickshell.env("HEIDR_AGENTD_SOCK")
            || (Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-" + root.scope + ".sock")
      connected: true
      parser: SplitParser { onRead: data => root.onLine(data) }
      onConnectionStateChanged: root.connected = connected
    }
  }
  Timer {
    interval: 2000; repeat: true; running: !root.connected
    onTriggered: { sockLoader.active = false; sockLoader.active = true }
  }
}
