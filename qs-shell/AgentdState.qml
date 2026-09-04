import QtQuick
import Quickshell
import Quickshell.Io
import QsLib

// Client for agentd's unix socket ($XDG_RUNTIME_DIR/agentd-<scope>.sock).
// On connect the daemon pushes {type:"roster",sessions:[...]}; it also streams
// per-session events (message_*/turn_*/agent_*) — feed wiring comes next.
// Commands go back as one-line JSON: {type:"prompt",session,text} (human, no `from`).
Item {
  id: root

  property string scope: "lovable"
  property var configuredSockPaths: null
  property bool connected: false
  property var sessions: []      // merged roster across every scope, each tagged .scope
  property int gen: 0            // bumped on every roster push

  function cockpitEnv(name) {
    return Quickshell.env("COCKPIT_" + name) || Quickshell.env("HEIDR_" + name)
  }

  // One socket per scope. COCKPIT_AGENTD_SOCKS (comma-separated) shows the local
  // orchestrator and a tunneled lovbox side by side; COCKPIT_AGENTD_SOCK (singular)
  // still selects a single daemon. Order matters: on a name collision the EARLIER
  // socket wins, so list the local scope first to keep it addressable.
  function envSockPaths() {
    if (configuredSockPaths !== null) return configuredSockPaths
    var multi = String(cockpitEnv("AGENTD_SOCKS") || "").trim()
    if (multi) return multi.split(",").map(p => p.trim()).filter(p => p.length > 0)
    var one = cockpitEnv("AGENTD_SOCK")
    return [one || (Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-" + root.scope + ".sock")]
  }
  property var sockPaths: envSockPaths()
  function attachSocket(path) {
    var p = String(path || "").trim()
    var prefix = Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-lovbox-"
    if (!p.startsWith(prefix) || !p.endsWith(".sock") || p.indexOf(",") >= 0) return false
    if (sockPaths.indexOf(p) >= 0) return true
    sockPaths = sockPaths.concat([p])
    settled = false
    return true
  }
  property var _rosters: ({})
  property var _health: ({})      // socket index -> daemon health string ("" = ok)
  property int healthGen: 0
  function healthSummary() {
    var out = []
    for (var k in _health) if (_health[k]) out.push(_health[k])
    return out.join(" · ")
  }   // socket index -> its sessions[]
  property var _sockOf: ({})    // session name -> owning socket index (routing table)
  property var _socks: ({})     // socket index -> Socket object
  property string presenceSession: ""

  function _scopeOf(path) {
    var m = String(path).match(/agentd-([^/]+)\.sock$/)
    return m ? m[1] : String(path)
  }
  function _rebuildSessions() {
    var out = [], owner = {}
    for (var i = 0; i < sockPaths.length; i++) {
      var arr = _rosters[i] || [], sc = _scopeOf(sockPaths[i])
      var up = !!(_socks[i] && _socks[i].connected)
      for (var j = 0; j < arr.length; j++) {
        var s = arr[j]
        if (owner[s.name] !== undefined) continue   // earlier socket owns the name
        owner[s.name] = i
        var tagged = {}
        for (var k in s) tagged[k] = s[k]
        tagged.scope = sc
        tagged.offline = !up
        if (!up) tagged.status = "offline"   // its daemon is gone; whatever it was
                                             // doing, we can no longer see or reach it
        out.push(tagged)
      }
    }
    _sockOf = owner
    root.sessions = out
    root.gen++
    for (var k in _socks) _writePresence(k)
  }
  // True once every CONNECTED socket has pushed its first roster, so consumers can
  // wait before picking a landing session. Without this the rail latches onto
  // whichever daemon answered first and then jumps (re-cd'ing nvim) when the second
  // one arrives a beat later.
  property bool settled: false
  property var _reported: ({})
  Timer {
    id: settleTimer
    interval: 2500   // a socket that connects but never pushes must not block forever
    onTriggered: root.settled = true
  }
  function _noteReported(i) {
    _reported[i] = true
    if (!settled && !settleTimer.running) settleTimer.start()
    for (var k in _socks)
      if (_socks[k] && _socks[k].connected && !_reported[k]) return
    settled = true
  }
  function _registerSock(i, obj) {
    _socks[i] = obj
    _recomputeConnected()
    _writePresence(i)
  }
  function _recomputeConnected() {
    var any = false
    for (var k in _socks) if (_socks[k] && _socks[k].connected) { any = true; break }
    root.connected = any
  }
  function _writePresence(i) {
    var s = _socks[i]
    if (!s || !s.connected) return
    var owner = presenceSession && _sockOf[presenceSession] !== undefined
              ? _sockOf[presenceSession] : -1
    s.write(JSON.stringify({ type: "presence", session: owner === Number(i) ? presenceSession : "" }) + "\n")
  }
  function setPresence(sid) {
    presenceSession = sid || ""
    for (var k in _socks) _writePresence(k)
  }

  // Per-session activity feed. `feeds` is mutated in place; `feedGen` bumps so
  // bindings recompute, and feedFor() returns a fresh slice so ListView refreshes.
  property var feeds: ({})
  property int feedGen: 0
  readonly property int feedCap: 200
  property var _availableModels: new Map()
  property int availableModelsGen: 0
  function modelsFor(sid) {
    availableModelsGen
    return _availableModels.get(sid) || []
  }

  // Pending ask_user questions (extension_ui_request): sid -> request obj
  // {id, method:"confirm"|"select"|"input"|"editor", title, message, options[]}.
  // One agent edit landed (tool_execution_start, edit-shaped) — for live-follow.
  signal editSeen(string sid, string path, string needleB64)
  // The edit's most distinctive inserted line (longest trimmed, >=3 chars),
  // base64ed for safe transport through --remote-expr quoting.
  function _editNeedle(tn, args) {
    var txt = ""
    if (args.edits && args.edits.length) {
      var last = args.edits[args.edits.length - 1]
      txt = String((last && (last.newText || last.new_text)) || "")
    }
    if (!txt) txt = String(args.newText || args.new_text || args.new_string || args.content || args.text || "")
    if (!txt) return ""
    var lines = txt.split("\n"), best = ""
    for (var i = 0; i < lines.length; i++) {
      var tl = lines[i].replace(/^\s+/, "").replace(/\s+$/, "")
      if (tl.length >= 3 && tl.length > best.length) best = tl
    }
    return best.length >= 3 ? Qt.btoa(best) : ""
  }
  // Fired when an edit's diff lands (tool_execution_end): the first hunk's
  // new-file line — cross-repo edits have no local diff data, so this is the
  // only line signal that always exists.
  signal editHunk(string sid, string path, int line)
  // What the session is DOING right now (last tool started this exchange) — feeds
  // the working orb's action hue.
  // sid -> Date.now() while a compaction is in flight (live glance feedback).
  property var _compacting: ({})
  function compactingSince(sid) { return _compacting[sid] || 0 }
  // sid -> Date.now() of the last session-tagged event (roster recency sort).
  // Map, not a plain object: these are written on EVERY daemon event, and inserting a
  // new key into a long-lived `property var` object is the exact path all four
  // quickshell segfaults died in (Object::insertMember, via the socket read handler).
  property var _lastAct: new Map()
  function lastActFor(sid) { return _lastAct.get(sid) || 0 }
  property var _curTool: new Map()
  property var _curToolAt: new Map()     // sid -> Date.now() of the RUNNING tool call
  property var _curToolLive: new Map()   // sid -> true while a tool call is executing
  property var _curToolId: new Map()     // sid -> toolCallId of the RUNNING call (feed row highlight)
  property int curToolGen: 0
  function curToolFor(sid) { return _curTool.get(sid) || "" }
  function curToolAtFor(sid) { return _curToolAt.get(sid) || 0 }
  function curToolLiveFor(sid) { return _curToolLive.get(sid) === true }
  function curToolIdFor(sid) { return _curToolId.get(sid) || "" }
  function _reconcileCurrentTools() {
    var authoritative = new Map()
    for (var index in _rosters) {
      var roster = _rosters[index] || []
      for (var i = 0; i < roster.length; i++) {
        var session = roster[i]
        var name = session.name || session.id || ""
        if (name && session.currentTool)
          authoritative.set(name, String(session.currentTool))
      }
    }

    var changed = false
    for (const name of Array.from(_curTool.keys())) {
      if (authoritative.has(name)) continue
      _curTool.delete(name)
      _curToolAt.delete(name)
      _curToolLive.delete(name)
      _curToolId.delete(name)
      changed = true
    }
    for (const [name, tool] of authoritative) {
      if (_curTool.get(name) === tool) continue
      _curTool.set(name, tool)
      changed = true
    }
    if (changed) curToolGen++
  }
  // Kill just the running tool call's subprocesses; the turn survives.
  function abortTool(sid) { send({ type: "abort_tool", session: sid }) }
  // Last file each session touched — so switching TO a mid-turn session can land
  // on the work instead of the dashboard.
  property var _lastEdit: ({})
  function lastEditFor(sid) { return _lastEdit[sid] || "" }

  property var asks: ({})
  property var _answerEchoes: ({})
  property var _answerIntents: ({})
  property int askGen: 0
  // A session stopped on a question — fired once per ask id, so the UI can badge
  // the roster and raise a desktop notification for NON-selected sessions (a
  // blocked background worker read as "working" for as long as nobody looked).
  signal askRaised(string sid, string title)
  function askCount() { var n = 0; for (var k in asks) n++; return n }
  function askFor(sid) { return asks[sid] || null }
  function isUserBashAsk(ask) { return ask && ask.title === "__cockpit_user_bash__" }
  function userBashPayload(ask) {
    if (!isUserBashAsk(ask)) return null
    try { return JSON.parse(String(ask.message || "")) } catch (e) { return null }
  }
  function answerAsk(sid, payload) {
    if (!asks[sid]) return
    var response = Object.assign({}, payload)
    var intents = _answerIntents
    if (response.discussing) {
      intents[sid] = "discussing"
      delete response.discussing
      _answerIntents = intents
    }
    if (!send({ type: "answer", session: sid, response: response })) {
      delete intents[sid]
      _answerIntents = intents
    }
  }

  // Per-session changed-files (from the daemon's `changes` diff broadcast).
  property var changes: ({})       // sid -> [{path, add, del}]
  property var changesCwd: ({})    // sid -> cwd (to resolve absolute paths)
  property int changesGen: 0
  function changesFor(sid)    { return (changes[sid] || []).slice() }
  function changesCwdFor(sid) { return changesCwd[sid] || "" }

  // Sockets are per-scope (see the Instantiator below); route each command to the
  // one that owns the target session, falling back to the first for global calls.
  function send(obj) {
    var idx = (obj && obj.session !== undefined && _sockOf[obj.session] !== undefined)
              ? _sockOf[obj.session] : 0
    var s = _socks[idx]
    if (!s || !s.connected) return false   // caller MUST surface this; a dropped
                                           // prompt that still echoed in the feed
                                           // looked exactly like a sent one.
    s.write(JSON.stringify(obj) + "\n")
    return true
  }
  // Sessions we've prompted but haven't heard back from yet. agentd only pushes a
  // roster when IT sees a state change, and over the tunnel the first event can be
  // ~40s out — so the badge said "idle" while the agent was already working and the
  // session looked hung. Treat "we just sent" as busy until the daemon confirms.
  property var pendingSends: ({})
  property int pendingGen: 0
  function isBusy(sid) {
    if (!sid) return false
    if (pendingGen >= 0 && pendingSends[sid]) return true
    for (var i = 0; i < sessions.length; i++)
      if (sessions[i].name === sid) return sessions[i].status === "streaming"
    return false
  }
  function _clearPending(sid) {
    if (!pendingSends[sid]) return
    var p = Object.assign({}, pendingSends); delete p[sid]; pendingSends = p; pendingGen++
  }
  // Local echoes that must SURVIVE transcript rebuilds. A steered message sits in pi's
  // queue until the next tool boundary, so it is absent from get_entries for seconds to
  // minutes — and the rebuild wiped the optimistic row, making mid-turn sends silently
  // vanish and then "all show up at once" when pi finally consumed them.
  property var _localEcho: ({})   // sid -> [{text, at}, …] not yet seen in the transcript
  function _echoTrack(sid, text) {
    var m = _localEcho; (m[sid] = m[sid] || []).push({ text: text, at: Date.now() }); _localEcho = m
  }
  function _settleEcho(sid, text) {
    var list = _localEcho[sid] || []
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].text === text && !list[i].settled) {
        list[i] = Object.assign({}, list[i], { settled: true })
        var echoes = _localEcho; echoes[sid] = list; _localEcho = echoes
        return
      }
    }
  }
  function _sessionStatus(sid) {
    for (var i = 0; i < sessions.length; i++)
      if (sessions[i].id === sid || sessions[i].name === sid) return sessions[i].status || ""
    return ""
  }
  function sendPrompt(sid, text) {
    // Moving on ends the interrupt bridge: without this, an accidental Esc
    // kept re-appending "interrupted by you" after every later message until
    // the 60s cap.
    var nmk = _marks; delete nmk[sid]; _marks = nmk
    // agentd/pi expect `message`, not `text`.
    if (!send({ type: "prompt", session: sid, message: text })) { _undelivered(sid, text); return }
    _push(sid, { kind: "user", text: text })   // optimistic echo; get_entries refreshes it
    _echoTrack(sid, text)
    var p = Object.assign({}, pendingSends); p[sid] = true; pendingSends = p; pendingGen++
  }
  // Mid-turn redirect. pi's steer is BEST-EFFORT: if the turn ends within a moment of
  // the steer it was too short to have consumed the message, and pi strands it unread.
  // Record when we steered so the turn_end handler can re-send it as a normal prompt —
  // the same strand-fallback the nvim rail runs.
  readonly property int steerGraceMs: 4000
  property var _steerPending: ({})
  function steer(sid, text) {
    if (!send({ type: "steer", session: sid, message: text })) { _undelivered(sid, text); return }
    _push(sid, { kind: "user", text: text, steered: true })
    _echoTrack(sid, text)
    _steerPending[sid] = { text: text, at: Date.now() }
  }
  // Queued prompts. Enter while the agent runs STEERS (redirect the live turn — the
  // default, it is what you usually mean); Ctrl+Enter QUEUES: the message waits for the
  // turn to end — a completed turn or an abort, both emit agent_end — then goes out as a
  // normal prompt. So aborting a turn with something queued picks the queued item up
  // immediately, the Claude Code model.
  property var queued: ({})        // sid -> [text, …] in send order
  property int queuedGen: 0
  function queuedFor(sid) { return (queued[sid] || []).length }
  function queuedFirst(sid) { var q = queued[sid] || []; return q.length ? q[0] : "" }
  function _flushQueue(sid) {
    var q = queued[sid] || []
    if (!q.length) return
    // One per turn boundary: the next flush happens on the next agent_end, so several
    // queued messages become a conversation, not a pile-up on pi's stdin.
    var nq = queued; nq[sid] = q.slice(1); if (!nq[sid].length) delete nq[sid]
    queued = nq; queuedGen++
    sendPrompt(sid, q[0])
  }
  function enqueue(sid, text) {
    if (!isBusy(sid)) { sendPrompt(sid, text); return }   // nothing to wait for
    var q = queued; (q[sid] = q[sid] || []).push(text); queued = q; queuedGen++
  }
  function submit(sid, text) {
    // A prompt IS the answer to a stale ask ("send a prompt with your answer to
    // continue"), so sending one retires the notice — leaving it up read as unanswered.
    dismissStaleAsk(sid)
    if (isBusy(sid)) steer(sid, text)
    else sendPrompt(sid, text)
  }
  function _undelivered(sid, text) {
    _push(sid, { kind: "cmd", tool: "error",
                 text: "not delivered — the " + _scopeOfSid(sid) + " daemon is disconnected" })
  }
  function _scopeOfSid(sid) {
    var i = _sockOf[sid]
    return (i === undefined) ? "agentd" : _scopeOf(sockPaths[i])
  }
  // Pull the authoritative transcript for a session without touching selection state
  // (select() also re-pins the feed). Used to keep a streaming session's chat live:
  // prose arrives via get_entries, not via message_* events, so a client that joins
  // mid-turn otherwise shows a frozen snapshot until the turn ends.
  function refreshEntries(sid) { if (sid) send({ type: "get_entries", session: sid }) }
  // Interrupt = abort the in-flight TURN; the session survives, idle, transcript
  // intact. This is pi's own rpc `abort` (Esc in its TUI) forwarded by agentd — and it
  // passes the daemon's blocked-on-a-question bounce, so it is also the escape hatch
  // for a session parked inside ask_user. Distinct from stop() below, which tears the
  // whole session down (kills pi, drops it from the roster).
  // Interrupt markers never exist in pi's transcript, so a plain _push vanished on the
  // next rebuild — an accidental Esc-abort looked like nothing happened at all. Keep the
  // last few per session and re-append them after every rebuild.
  // Transient status rows (retries, compaction, extension errors): pushed live AND
  // re-appended after transcript rebuilds — they are not transcript entries, so a
  // rebuild otherwise wipes them mid-retry. Keyed per kind so an end-event replaces
  // or clears its start; ttl caps anything whose end never arrives.
  property var _transients: ({})   // sid -> { kindKey: {tool, text, at, ttl} }
  // quiet: record the transient WITHOUT pushing a feed row. A row pushed here is
  // permanent — _clearTransient drops the record but cannot retract the row — so a
  // progress message with a terminal event ("compacting context…") sat in the feed
  // forever once the work finished. Progress belongs in the live indicator
  // (compactingSince); the feed keeps only durable facts, e.g. errors.
  function _setTransient(sid, key, tool, text, ttl, quiet) {
    var t = _transients; (t[sid] = t[sid] || {})[key] = { tool: tool, text: text, at: Date.now(), ttl: ttl }
    _transients = t
    if (!quiet) _push(sid, { kind: "cmd", tool: tool, text: text })
  }
  function _clearTransient(sid, key) {
    var t = _transients
    if (t[sid] && t[sid][key]) { delete t[sid][key]; _transients = t }
  }
  property var _marks: ({})   // sid -> [text, …] (capped)
  property var _myAbortAt: ({})   // sid -> ms of the last abort WE sent (attribution)
  function myAbortAgoFor(sid) { return _myAbortAt[sid] ? (Date.now() - _myAbortAt[sid]) : -1 }
  function interrupt(sid) {
    if (!sid) return
    if (!send({ type: "abort", session: sid })) return
    var ab = _myAbortAt; ab[sid] = Date.now(); _myAbortAt = ab
    delete _steerPending[sid]
    _clearPending(sid)
    var mk = _marks; var l = (mk[sid] = mk[sid] || [])
    l.push({ text: "⏹ interrupted by you", at: Date.now() })
    if (l.length > 3) l.shift()
    _marks = mk
    _push(sid, { kind: "cmd", tool: "error", text: "⏹ interrupted — turn aborted" })
  }
  function stop(sid) {
    send({ type: "stop", session: sid })
    delete _steerPending[sid]      // an aborted turn must not resurrect the steer
    _clearPending(sid)
  }
  function feedFor(sid)          { return (feeds[sid] || []).slice() }

  // "/skill:plan-ticket EVERY-2741" + 400 lines of skill body → just the invocation,
  // with the size noted so it's clear something was expanded rather than lost.
  function _foldSlashBody(t) {
    var s0 = String(t || "")
    // pi expands a /skill invocation into an inline <skill ...>...</skill> block
    // (the whole SKILL.md); render it as a one-line chip, keep any real text.
    var sk = /<skill\s+name="([^"]+)"[^>]*>[\s\S]*?<\/skill>\s*/g
    if (sk.test(s0)) {
      s0 = s0.replace(sk, function(_, n) { return "_(/" + n + " — skill instructions folded)_\n" }).trim()
    }
    if (s0.charAt(0) !== "/") return s0
    var nl = s0.indexOf("\n")
    if (nl < 0 || s0.length < 400) return s0
    var head = s0.slice(0, nl).trim()
    var lines = s0.slice(nl + 1).split("\n").length
    return head + "\n\n_(expanded " + lines + " lines of skill instructions)_"
  }
  function _base(p)  { var s = String(p); var i = s.lastIndexOf("/"); return i >= 0 ? s.slice(i + 1) : s }
  function _rel(p)   { var s = String(p || ""); return s.replace(/^\/home\/daphen\//, "~/") }
  function _clip(s)  { s = String(s || "").replace(/\s+/g, " "); return s.length > 72 ? s.slice(0, 69) + "…" : s }

  // Mirror of the nvim rail's tool_hint: name + the bit that matters. MCP calls
  // become "mcp <server> <tool>" / "mcp <server> search:<x>" — not "bash mcp".
  // Normalize an ask_user result into the words the user chose: {"confirmed":true}
  // reads as approved, a typed value reads as itself.
  function _askAnswerText(r) {
    if (r === undefined || r === null) return ""
    if (typeof r === "string") {
      try { r = JSON.parse(r) } catch (e) { return r }
    }
    if (r && r.content) {
      var out = []
      for (var i = 0; i < r.content.length; i++)
        if (r.content[i].type === "text") out.push(String(r.content[i].text || ""))
      return _askAnswerText(out.join("\n"))
    }
    if (r && r.cancelled) return "cancelled"
    if (r && r.confirmed !== undefined) return r.confirmed ? "approved" : "declined"
    if (r && r.value !== undefined) return String(r.value)
    return typeof r === "object" ? JSON.stringify(r) : String(r)
  }
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
    if (name === "agent_send")   return "send → " + (a.agent || "?") + " · " + _clip(a.message)
    if (name === "agent_steer")  return "steer → " + (a.agent || "?") + " · " + _clip(a.message)
    if (name === "agent_spawn")  return "spawn → " + (a.name || _base(a.dir || "?")) + (a.detached ? " (top-level)" : "")
    if (name === "agent_read")   return "read ← " + (a.agent || "?")
    if (name === "agent_review") return "review PR " + (a.pr || "")
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
  // cwdOverride: a REMOTE session's cwd is a VM path that no local git can read, so
  // the caller passes the vm-sync mirror instead (only Rail knows that mapping).
  function refreshChanges(sid, cwdOverride) {
    var cwd = cwdOverride || ""
    for (var i = 0; !cwd && i < sessions.length; i++)
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
    // Diff from the MERGE-BASE, not origin/main itself: a two-dot diff against a
    // moving main counts every unrelated commit main gained since the fork as this
    // session's changes (584 phantom files on a branch with zero work).
    command: ["sh", "-c",
      "cd " + JSON.stringify(cwdArg) + " 2>/dev/null && { b=$(git merge-base origin/main HEAD 2>/dev/null || git rev-parse -q --verify HEAD 2>/dev/null || echo 4b825dc642cb6eb9a060e54bf8d69288fbee4904); git diff --no-color --no-ext-diff --unified=0 \"$b\" 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null | grep -v '^\\.heidr-pastes/' | while IFS= read -r f; do printf 'diff --git a/%s b/%s\\n+++ b/%s\\n' \"$f\" \"$f\" \"$f\"; n=$(wc -l < \"$f\" 2>/dev/null || echo 0); i=0; while [ $i -lt $n ] && [ $i -lt 500 ]; do printf '+\\n'; i=$((i+1)); done; done; }"]
    stdout: StdioCollector {
      onStreamFinished: {
        var sid = root._pendingChangesSid
        if (sid) { root.changes[sid] = root._parseChanges(this.text); root.changesCwd[sid] = gitProc.cwdArg; root.changesGen++ }
      }
    }
  }

  // Expand an assistant message's content blocks into feed items (mirror of the
  // nvim rail's msg_text): prose (text), collapsed thinking, and tool calls.
  function _expandAssistant(content, items, toolErrs, toolResults) {
    toolErrs = toolErrs || {}
    toolResults = toolResults || {}
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
        } else if (name === "request_user_bash") {
          var ub = toolResults[b.id] || ""
          items.push({ kind: "userbash", tool: name, command: String(a.command || ""),
                       reason: String(a.reason || ""), result: ub, text: ub,
                       failed: toolErrs[b.id] === true })
        } else if (name === "ask_user") {
          // The QUESTION AND ANSWER live here in the transcript (the answer is the
          // tool call's result) — render them as a persistent row, or the answered
          // question only ever existed as an optimistic push the next rebuild ate.
          var q = String(a.title || a.message || "question")
          // User-bash approval asks carry a sentinel title + JSON payload; render
          // the actual command (matches the live echo, which retires against this row).
          if (a.title === "__cockpit_user_bash__") {
            try { q = "! " + String(JSON.parse(String(a.message || "")).command || "") } catch (e) {}
          }
          var ans = _askAnswerText(b.result)
          items.push({ kind: "cmd", tool: "ask",
                       text: ans ? ("❯ " + q + "  ↳ " + _clip(ans)) : ("❯ " + q),
                       command: ans.length > 72 ? ans : "" })
        } else {
          items.push({ kind: "cmd", tool: name, text: toolHint(name, a),
                       failed: toolErrs[b.id] === true,
                       command: (name === "bash" || name === "shell") ? (a.command || a.cmd || "") : "" })
        }
      }
    }
  }

  // Reconstruct the active branch (leaf→root via parentId) into a flat feed.
  // Formatting only — takes the message tail (from here or from the worker) and builds
  // feed items. Cheap: it never sees more than CHAT_CAP messages.
  function _msgsToFeed(msgs, toolErrs, sid, toolResults) {
    toolErrs = toolErrs || {}
    toolResults = toolResults || {}
    var items = []
    for (var mi = 0; mi < msgs.length; mi++) {
      var msg = msgs[mi]
      var isLast = (mi === msgs.length - 1)
      var prevAborted = mi > 0 && msgs[mi - 1].role === "assistant" && msgs[mi - 1].stopReason === "aborted"
      var _from = items.length
      if (msg.role === "userBashApproval") {
        items.push({ kind: "cmd", tool: "ask",
                     text: "❯ ! " + String(msg.command || "") + "  ↳ approved" })
      } else if (msg.role === "user") {
        var uc = msg.content || [], ut = ""
        for (var k = 0; k < uc.length; k++) if (uc[k].type === "text" && uc[k].text) ut += (ut ? "\n" : "") + uc[k].text
        ut = ut.replace(/\s*<system-reminder>[\s\S]*?<\/system-reminder>\s*/g, "\n").trim()
        ut = _foldSlashBody(ut)
        if (ut) {
          // Relayed prompts arrive sender-stamped by the daemon ("⇄ <name>" first
          // line, #84): lift the sender into the row instead of showing it as text.
          var sender = ""
          if (ut.indexOf("\u21c4 ") === 0) {
            var nl = ut.indexOf("\n")
            sender = (nl > 0 ? ut.slice(2, nl) : ut.slice(2)).trim()
            ut = nl > 0 ? ut.slice(nl + 1).trim() : ""
          }
          if (ut || sender) items.push({ kind: "user", text: ut, steered: prevAborted, sender: sender })
        }
      } else if (msg._compaction) {
        // sys, not cmd: compaction is housekeeping between turns — inlining it in
        // the following turn's card made its neighbors ("output truncated") read
        // as compaction failures.
        items.push({ kind: "sys", tool: "info", text: "· context compacted" })
      } else {
        _expandAssistant(msg.content, items, toolErrs, toolResults)
        // A failed assistant turn carries its reason on the MESSAGE, not the content —
        // it rendered as a bare "1 error" chip with nothing to read. Name it: a user
        // abort gets the interrupt grammar, anything else shows the provider's message.
        if (msg.stopReason === "aborted") {
          // Three different events share stopReason "aborted":
          //   mid-chain  → a steer redirected the turn and work continued (muted)
          //   trailing + we sent an abort recently → YOU interrupted (red ⏹)
          //   trailing, no abort of ours → something ELSE stopped it — another
          //     client, the orchestrator, or the agent tripping its own keybinds
          if (!isLast) {
            items.push({ kind: "cmd", tool: "info", text: "· redirected mid-turn (steer)" })
          } else if (sid && _myAbortAt[sid] && (Date.now() - _myAbortAt[sid]) < 600000) {
            items.push({ kind: "cmd", tool: "error", text: "⏹ interrupted by you" })
          } else {
            items.push({ kind: "cmd", tool: "error", text: "⚡ aborted externally — another client or the agent itself stopped this turn" })
          }
        } else if (msg.stopReason === "error" || msg.errorMessage) {
          var em = String(msg.errorMessage || "unknown error")
          items.push({ kind: "cmd", tool: "error",
                       text: /abort/i.test(em) ? "⏹ interrupted — turn aborted (yours or a steer)"
                                               : "✗ " + em })
        } else if (msg.stopReason === "length") {
          // The reply hit the output cap: pi/Claude Code warn; silence read as a
          // complete answer that just… ended.
          items.push({ kind: "cmd", tool: "error", text: "⚠ response hit its output cap and was cut off — send “continue” to resume" })
        } else {
          // Every agent card must STATE ITS OUTCOME. A turn-closing assistant message
          // with tools but no prose (the ⟢-summary contract violated, usually after
          // tool errors) rendered as bare chips — say mechanically what happened.
          // isLast alone is NOT "the turn ended": mid-turn, the newest assistant message
          // is always last while more tool calls are still coming, so a running turn got
          // labelled as ended without a summary. A live session closes nothing.
          var closes = (isLast && _sessionStatus(sid) !== "streaming")
            || (msgs[mi + 1] && (msgs[mi + 1].role === "user" || msgs[mi + 1]._compaction))
          if (closes) {
            var ntools = 0, nerrs = 0, hastext = false
            for (var si = _from; si < items.length; si++) {
              var it = items[si]
              if (it.kind === "text") hastext = true
              if (it.kind === "cmd" || it.kind === "edit") { ntools++; if (it.failed) nerrs++ }
            }
            if (!hastext && ntools > 0)
              items.push({ kind: "cmd", tool: nerrs ? "error" : "info",
                           text: "· turn ended without a summary — " + ntools + " tool call" + (ntools > 1 ? "s" : "")
                               + (nerrs ? " (" + nerrs + " failed)" : "") })
            else if (!hastext && ntools === 0)
              items.push({ kind: "cmd", tool: "info", text: "· turn produced no output" })
          }
        }
      }
      for (var ti = _from; ti < items.length; ti++)
        // (message id, nth item OF THAT MESSAGE) — `ti` alone is the index into the
        // whole items array, which slides with the window and is not an identity.
        if (msg._mid && !items[ti].mid) items[ti].mid = msg._mid + ":" + (ti - _from)
    }
    return _coalesce(items)
  }

  property string _feedSid: ""
  function _entriesToFeed(entries, leafId) {
    var byid = {}
    for (var i = 0; i < entries.length; i++) if (entries[i].id) byid[entries[i].id] = entries[i]
    var cur = leafId
    if (!cur && entries.length) cur = entries[entries.length - 1].id
    var chain = [], seen = {}
    while (cur && byid[cur] && !seen[cur]) { seen[cur] = true; chain.push(byid[cur]); cur = byid[cur].parentId }
    // Collect user/assistant messages chronologically, then only format the TAIL —
    // a big transcript (3000+ entries / 7MB) is otherwise multi-second to expand.
    var msgs = [], toolErrs = {}, toolResults = {}
    for (var j = chain.length - 1; j >= 0; j--) {
      var e = chain[j]
      // Failed tool calls: the isError flag lives on the toolResult MESSAGE, not the
      // call — collect per callId so the call's row can render as a failure.
      if (e.type === "message" && e.message && e.message.role === "toolResult") {
        if (e.message.toolCallId) {
          if (e.message.isError) toolErrs[e.message.toolCallId] = true
          var rt = "", rc = e.message.content || []
          for (var ri = 0; ri < rc.length; ri++)
            if (rc[ri].type === "text" && rc[ri].text) rt += (rt ? "\n" : "") + rc[ri].text
          toolResults[e.message.toolCallId] = rt
        }
        continue
      }
      // Compaction is a fact about the conversation; pi/Claude Code both mark it.
      if (e.type === "compaction") {
        msgs.push({ role: "assistant", content: [], _compaction: true, _mid: e.id })
        continue
      }
      if (e.type === "custom" && e.customType === "cockpit-user-bash-approval"
          && e.data && e.data.decision === "approved") {
        msgs.push({ role: "userBashApproval", command: e.data.command || "", _mid: e.id })
        continue
      }
      if (e.type === "message" && e.message && (e.message.role === "user" || e.message.role === "assistant")) {
        // Stamp the entry id onto the message: feed rows need an identity that survives
        // the CHAT_CAP window sliding, or every row's INDEX shifts by one per new message
        // and anything keyed on it (the cursor, expanded groups) lands on a neighbour.
        e.message._mid = e.id
        msgs.push(e.message)
      }
    }
    var CHAT_CAP = 60
    return _msgsToFeed(msgs.slice(Math.max(0, msgs.length - CHAT_CAP)), toolErrs, _feedSid, toolResults)
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
          out.push({ kind: "group", tool: it.tool, cmds: cmds, mid: it.mid })
          i = j
          continue
        }
      }
      out.push(it)
      i++
    }
    return out
  }

  // agentd trims a get_entries reply to its last entries before relaying, so what lands
  // here is a few MB rather than the whole history — parsing it inline is fine.
  //
  // It was NOT fine before that trim, and the failure was subtle: pi returns ~20MB for a
  // long-running session, and Quickshell's socket reader truncates the line about 23KB
  // short, so the json never parsed on ANY thread. A WorkerScript detour only moved the
  // failure — and handing it a 20MB string aborted the process outright.
  readonly property int maxLineBytes: 32 * 1024 * 1024
  function onLine(data, sockIdx) {
    if (data.length > maxLineBytes) return
    let m
    try { m = JSON.parse(data) } catch (e) { return }
    if (!m) return
    const t = m.type
    if (t === "roster") {
      var si = sockIdx || 0
      _rosters[si] = m.sessions || []
      // Daemon-level health (boot self-check): "" = fine; anything else is a broken
      // pi contract every session on that daemon shares — surface it, loudly.
      var hh = _health
      if (String(m.health || "") !== String(hh[si] || "")) { hh[si] = String(m.health || ""); _health = hh; healthGen++ }
      _noteReported(si)
      _rebuildSessions()
      _reconcileCurrentTools()
      // Rosters are authoritative for asks: clearing used to depend solely on
      // catching the ask_answered event, so a rail that was relaunching or
      // disconnected at that moment kept a ghost card forever — which hides
      // the composer. Prune any ask no daemon still claims.
      var claimed = {}
      for (var rsi in _rosters) {
        var lst = _rosters[rsi] || []
        for (var rj = 0; rj < lst.length; rj++) if (lst[rj].ask) claimed[lst[rj].name] = true
      }
      var prunedAsk = false
      var a2 = asks
      for (var ak in a2) if (!claimed[ak]) { delete a2[ak]; prunedAsk = true }
      if (prunedAsk) { asks = a2; askGen++ }
      return
    }
    if (t === "response" && m.command === "get_entries") { onEntries(m); return }
    if (t === "response" && m.command === "get_available_models" && m.session) {
      _availableModels.set(m.session, (m.data && m.data.models) || [])
      availableModelsGen++
      return
    }
    const sid = m.session
    if (!sid) return
    // Recency: any session-tagged event is activity. Silent (no gen bump) — the
    // roster re-sorts on the daemon's own roster pushes, which land at exactly
    // the status boundaries where order should change.
    _lastAct.set(sid, Date.now())
    // The daemon is talking about this session, so its real status is authoritative now.
    if (t === "turn_end" || t === "agent_end" || t === "error") root._clearPending(sid)
    if (t === "agent_end") { _curTool.delete(sid); curToolGen++ }
    // The whole turn is over (completed or aborted) → the next queued message goes out.
    if (t === "agent_end") root._flushQueue(sid)
    // A daemon bounce (undeliverable prompt, lineage refusal) was invisible — the send
    // echoed optimistically and then nothing. Surface it as a feed row.
    if (t === "error" && m.error) _push(sid, { kind: "cmd", tool: "error", text: String(m.error) })
    // Strand fallback: the turn ended too soon after a steer to have consumed it, so
    // pi dropped the message. Re-send it as a fresh prompt (already echoed in the feed).
    if (t === "turn_end" || t === "agent_end") {
      var sp = _steerPending[sid]
      delete _steerPending[sid]
      if (sp && (Date.now() - sp.at) < steerGraceMs)
        send({ type: "prompt", session: sid, message: sp.text })
      else if (sp)
        _settleEcho(sid, sp.text)
    }

    if (t === "prompt_accepted") {
      var accepted = String(m.message || "")
      if (accepted.length) {
        _push(sid, { kind: "user", text: accepted, steered: m.steered === true })
        _echoTrack(sid, accepted)
      }
      return
    }
    if (t === "goal_set") {
      var goal = String(m.goal || "")
      _setTransient(sid, "goal-receipt", "info",
                    goal.length ? "↳ goal pinned (watchdog on): " + goal : "↳ goal cleared", 60000)
      return
    }
    if (t === "plan_set") {
      var plan = String(m.plan || "")
      _setTransient(sid, "plan-receipt", "info",
                    plan.length ? "↳ plan bound: " + plan : "↳ plan cleared", 60000)
      return
    }
    if (t === "ask_answered") {
      var intent = _answerIntents[sid] || ""
      var intents = _answerIntents; delete intents[sid]; _answerIntents = intents
      var label = m.cancelled ? (intent === "discussing" ? "discussing instead" : "cancelled")
                : (m.confirmed !== undefined ? (m.confirmed ? "approved" : "declined")
                : (m.value !== undefined ? String(m.value) : ""))
      var asked = asks[sid]
      var bp = userBashPayload(asked)
      if (label && !bp) {
        // Carry the QUESTION with the echo: the card vanishes on answer, so a bare
        // "↳ approved" left no trace of what was approved — consecutive answers read
        // as one duplicated reply.
        var q = asked ? String(asked.title || asked.message || "").split("\n")[0] : ""
        if (q.length > 72) q = q.slice(0, 71) + "…"
        var echo = "↳ " + label + (q ? " — " + q : "")
        var echoes = _answerEchoes
        var list = (echoes[sid] || []).slice(-4)
        list.push({ text: echo, at: Date.now(), q: q })
        echoes[sid] = list
        _answerEchoes = echoes
        _push(sid, { kind: "user", text: echo })
      }
      var answered = asks; delete answered[sid]; asks = answered; askGen++
      return
    }
    if (t === "extension_ui_request") {
      var mm = m.method
      if (mm === "confirm" || mm === "select" || mm === "input" || mm === "editor") {
        var isNew = !asks[sid] || asks[sid].id !== m.id
        var na = asks; na[sid] = m; asks = na; askGen++
        if (isNew) askRaised(sid, String(m.title || m.message || "needs your input"))
      }
      // notify / setStatus / setWidget etc. are UI directives, not questions.
      return
    }
    if (t === "changes") {
      changes[sid] = _parseChanges(m.diff || "")
      changesCwd[sid] = m.cwd || ""
      changesGen++
      return
    }
    if (t === "tool_execution_start") {
      const tn = m.toolName || ""
      const args = m.args || {}
      _curTool.set(sid, AgentActivity.classify(tn, args))
      _curToolAt.set(sid, Date.now())
      _curToolLive.set(sid, true)
      _curToolId.set(sid, m.toolCallId || "")
      curToolGen++
      if (tn === "edit" || tn === "write" || tn === "create" || tn === "str_replace") {
        _push(sid, { kind: "edit", tool: tn, file: _base(args.path || ""), path: args.path || "",
                     add: 0, del: 0, id: m.toolCallId })
        if (args.path) {
          var le = _lastEdit; le[sid] = String(args.path); _lastEdit = le
          root.editSeen(sid, String(args.path), _editNeedle(tn, args))
        }
      } else {
        // bash/mcp/grep/read/… → one-line hint; keep the raw payload so the row
        // can EXPAND: bash shows its command, agent_* shows target + full message.
        var raw = ""
        if (tn === "bash" || tn === "shell") raw = args.command || args.cmd || ""
        else if (tn === "agent_send" || tn === "agent_steer")
          raw = "to: " + (args.agent || "?") + "\n\n" + (args.message || "")
        else if (tn === "agent_spawn")
          raw = "dir: " + (args.dir || "?") + (args.name ? "\nname: " + args.name : "")
              + (args.profile ? "\nprofile: " + args.profile : "") + (args.detached ? "\ndetached: true" : "")
              + (args.prompt ? "\n\nseed prompt:\n" + args.prompt : "")
        _push(sid, { kind: "cmd", tool: tn, text: toolHint(tn, args), command: raw, id: m.toolCallId })
      }
    } else if (t === "auto_retry_start") {
      _setTransient(sid, "retry", "info",
                    "↻ retrying (" + (m.attempt || 1) + "/" + (m.maxAttempts || "?") + ") — "
                    + _clip(String(m.errorMessage || "transient provider error")), 180000)
    } else if (t === "auto_retry_end") {
      _clearTransient(sid, "retry")
      if (m.success === false)
        _setTransient(sid, "retry", "error", "✗ retries exhausted — " + _clip(String(m.finalError || "provider error")), 120000)
    } else if (t === "compaction_start") {
      _setTransient(sid, "compact", "info", "· compacting context…", 300000, true)
      var cm = _compacting; cm[sid] = Date.now(); _compacting = cm; curToolGen++
    } else if (t === "compaction_end") {
      _clearTransient(sid, "compact")
      var cm2 = _compacting; delete cm2[sid]; _compacting = cm2; curToolGen++
      // Only FAILURE gets a transient. The success marker already arrives as a
      // `compaction` event in the transcript and renders as its own card at the
      // boundary; a tail transient duplicated it 60s and read as a stray message.
      if (m.errorMessage)
        _setTransient(sid, "compact", "error",
                      "✗ compaction failed — " + _clip(String(m.errorMessage)), 60000)
    } else if (t === "extension_error") {
      _setTransient(sid, "ext:" + _clip(String(m.error || m.message || "")).slice(0, 24), "error",
                    "✗ extension error — " + _clip(String(m.error || m.message || "unknown")), 120000)
    } else if (t === "tool_aborted") {
      _setTransient(sid, "toolkill", "error",
                    "⨯ killed the running tool call (" + (m.killed || 0) + " process" + ((m.killed || 0) === 1 ? "" : "es") + ") — the turn continues", 60000)
    } else if (t === "tool_execution_end") {
      _curToolLive.delete(sid)
      _curToolId.delete(sid)
      curToolGen++
      const det = m.result && m.result.details
      // A failed tool run turns its own row red in place (Claude Code grammar).
      if (m.result && m.result.isError) {
        var fa = feeds[sid] || []
        for (var fj = fa.length - 1; fj >= 0; fj--)
          if (fa[fj].id === m.toolCallId) { fa[fj].failed = true; break }
        feeds[sid] = fa; feedGen++
      }
      if (det && det.diff) {
        const ad = _countDiff(det.diff)
        var arr = feeds[sid] || []
        for (var i = arr.length - 1; i >= 0; i--) {
          if (arr[i].id === m.toolCallId) {
            arr[i].add = ad[0]; arr[i].del = ad[1]
            // LAST hunk header, not the first: a multi-hunk edit's newest change
            // is the one the eye should land on.
            var hms = String(det.diff).match(/@@ -\d+(?:,\d+)? \+(\d+)/g)
            if (hms && hms.length && arr[i].path) {
              var lastH = hms[hms.length - 1].match(/\+(\d+)/)
              if (lastH) root.editHunk(sid, String(arr[i].path), parseInt(lastH[1]))
            }
            break
          }
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
    _feedSid = esid
    feeds[esid] = _entriesToFeed(m.data.entries, m.data.leafId)
    // Answer echoes are a BRIDGE, not history (same contract as the interrupt
    // marks below): pi's transcript renders the answered ask itself once the
    // toolResult lands ("❯ question ↳ answer"), so an echo re-appended past that
    // point duplicates the answer at the bottom of every later rebuild — hard
    // 60s cap, exactly like the marks' never-caught-up guard.
    // An echo is spent as soon as the rebuilt transcript renders the answered
    // ask itself ("❯ question ↳ answer") — and, regardless, after 10s. It exists
    // only to bridge the rebuild that would otherwise eat the just-pushed echo;
    // user-bash approvals never produce a transcript ask row (the command renders
    // as its own bash card), so a long clock meant the echo kept re-appending
    // BELOW newer turns on every rebuild. Brief and gone beats sticky and wrong.
    var answers = (_answerEchoes[esid] || []).filter(a => {
      if (typeof a !== "object" || (Date.now() - (a.at || 0)) >= 10000) return false
      var qkey = String(a.q || "").slice(0, 40)
      if (!qkey.length) return true
      for (var fi = 0; fi < feeds[esid].length; fi++) {
        var it = feeds[esid][fi]
        if (it.kind === "cmd" && it.tool === "ask"
            && String(it.text || "").indexOf("↳") >= 0
            && String(it.text || "").indexOf(qkey) >= 0) return false
      }
      return true
    })
    var ne = _answerEchoes
    if (answers.length) ne[esid] = answers; else delete ne[esid]
    _answerEchoes = ne
    for (var ai = 0; ai < answers.length; ai++)
      feeds[esid].push({ kind: "user", text: answers[ai].text })
    // Interrupt markers are a BRIDGE, not history: pi records the aborted turn
    // itself (stopReason → the "⏹ interrupted" item), so once the rebuilt feed
    // carries any interrupt row the marks are duplicates — drop them for good.
    // Before that they re-append FIRST, echoes second: the user's just-steered
    // message is the newest thing they did.
    var mks = _marks[esid] || []
    if (mks.length) {
      // A mark bridges rebuilds only until pi's own stopReason row lands — and if the
      // abort never reached a turn (dead pi), that row never comes, so a hard 60s cap
      // keeps a mark from re-appending forever after every later message.
      var caughtUp = false
      for (var fi = 0; fi < feeds[esid].length && !caughtUp; fi++) {
        var its = feeds[esid][fi].items || []
        for (var ii = 0; ii < its.length; ii++) {
          // Any abort-derived row counts: once later messages exist, pi's own
          // row renders as the mid-chain steer marker, not "⏹ interrupted".
          var mt = String(its[ii].text || "")
          if (mt.indexOf("⏹ interrupted") === 0 || mt.indexOf("· redirected mid-turn") === 0
              || mt.indexOf("⚡ aborted externally") === 0) { caughtUp = true; break }
        }
      }
      mks = caughtUp ? [] : mks.filter(mm => (Date.now() - (mm.at || 0)) < 60000)
      var nm = _marks
      if (mks.length) nm[esid] = mks; else delete nm[esid]
      _marks = nm
    }
    for (var mi = 0; mi < mks.length; mi++)
      feeds[esid].push({ kind: "cmd", tool: "error", text: mks[mi].text !== undefined ? mks[mi].text : mks[mi] })
    var trs = _transients[esid] || {}
    for (var tk in trs) {
      if (Date.now() - trs[tk].at > trs[tk].ttl) { _clearTransient(esid, tk); continue }
      feeds[esid].push({ kind: "cmd", tool: trs[tk].tool, text: trs[tk].text })
    }
    // Keep local echoes the transcript has not caught up with. Consumed steers that pi
    // never records stay anchored before their response instead of following the bottom.
    var q = _localEcho[esid] || []
    if (q.length) {
      var corpus = []
      for (var i = 0; i < m.data.entries.length; i++) {
        var msg = (m.data.entries[i] || {}).message
        if (msg && msg.role === "user")
          for (var c = 0; c < (msg.content || []).length; c++)
            if (msg.content[c].type === "text") corpus.push(String(msg.content[c].text || ""))
      }
      var joined = corpus.join("\n\u0000")
      var left = []
      var idle = _sessionStatus(esid) !== "streaming"
      var settledAnchor = feeds[esid].length, settledMid = ""
      for (var au = feeds[esid].length - 1; au >= 0; au--) {
        if (feeds[esid][au].kind !== "user") continue
        settledAnchor = Math.min(au + 1, feeds[esid].length)
        if (settledAnchor < feeds[esid].length)
          settledMid = String(feeds[esid][settledAnchor].mid || "")
        break
      }
      for (var qi = 0; qi < q.length; qi++) {
        var qe = q[qi], qt = qe.text !== undefined ? qe.text : String(qe)
        if (joined.indexOf(qt) >= 0) continue             // transcript caught up
        // A /skill invocation is RECORDED expanded (<skill name=...> replaces the
        // literal text), so the echo never matched and re-appended forever.
        var sk = qt.match(/^\/(?:skill:)?([\w-]+)\b/)
        if (sk && joined.indexOf('<skill name="' + sk[1] + '"') >= 0) continue
        // An echo can wait out a long tool run while a STREAMING turn holds the steer —
        // but an IDLE session with a stale echo means the message provably died (pi
        // rejected or never received it). Say so once instead of ghosting it forever.
        var age = Date.now() - (qe.at || 0)
        if (idle && age > 30000) {
          feeds[esid].push({ kind: "cmd", tool: "error",
                             text: "✗ not delivered — the agent never received: “" + qt.slice(0, 80) + "”. Resend it." })
          continue                                        // dropped from the queue
        }
        var insertAt = feeds[esid].length
        if (qe.beforeMid) {
          for (var bi = 0; bi < feeds[esid].length; bi++)
            if (feeds[esid][bi].mid === qe.beforeMid) { insertAt = bi; break }
        } else if (qe.settled) {
          insertAt = settledAnchor
          if (settledMid) {
            qe = Object.assign({}, qe, { beforeMid: settledMid })
            for (var si = 0; si < feeds[esid].length; si++)
              if (feeds[esid][si].mid === settledMid) { insertAt = si; break }
          }
        }
        left.push(qe)
        feeds[esid].splice(insertAt, 0, { kind: "user", text: qt })
      }
      var le = _localEcho
      if (left.length) le[esid] = left; else delete le[esid]
      _localEcho = le
    }
    for (var li = feeds[esid].length - 1; li >= 0; li--) {
      var lit = feeds[esid][li]
      var lp = lit.kind === "edit" ? lit.path
             : (lit.kind === "turn" && lit.items) ? (function (its) {
                 for (var lj = its.length - 1; lj >= 0; lj--)
                   if (its[lj].kind === "edit" && its[lj].path) return its[lj].path
                 return ""
               })(lit.items) : ""
      if (lp) { var le2 = _lastEdit; le2[esid] = String(lp); _lastEdit = le2; break }
    }
    feedGen++
    _recoverAsk(esid, m.data.entries)
  }

  // A pending ask is normally learned from a live extension_ui_request. A client that
  // wasn't connected when it fired — or that reloaded since — never sees it, so the
  // session sits blocked while the UI shows nothing but "thinking". Rebuild it from the
  // transcript: an ask_user call with no matching result is still waiting on you.
  function _recoverAsk(sid, entries) {
    var calls = [], answered = {}, lastCallId = ""
    function walk(o) {
      if (!o || typeof o !== "object") return
      if (o.type === "toolCall") {
        lastCallId = o.id || lastCallId          // track the most recent call of ANY kind
        if (o.name === "ask_user") {
          calls.push(o)
          if (o.result !== undefined) answered[o.id] = true
        }
      }
      var rid = o.toolCallId
      if (rid && (o.type === "toolResult" || o.result !== undefined || o.output !== undefined))
        answered[rid] = true
      for (var k in o) walk(o[k])
    }
    for (var i = 0; i < entries.length; i++) walk(entries[i])
    var open = null
    for (var j = calls.length - 1; j >= 0; j--)
      if (!answered[calls[j].id]) { open = calls[j]; break }
    _applyRecoveredAsk(sid, open, lastCallId)
  }

  // An ask rebuilt from a transcript is NOT answerable. pi mints the request id with
  // crypto.randomUUID() and keeps the resolver in the live process's memory (rpc-mode's
  // createDialogPromise), so that id never reaches the transcript and dies with the
  // process. Answering a recovered card therefore sent an id pi had never heard of: it
  // was ignored, the transcript stayed unanswered, and the next 5s refresh republished
  // the SAME question — a card that came back forever no matter how often you answered.
  // So recovered asks go here, separate from the answerable `asks`, and surface as a
  // dismissible notice instead.
  property var staleAsks: ({})        // sid -> {id, title, message}
  property int staleAskGen: 0
  property var _askDismissed: ({})    // ask id -> true, so a dismissal survives refreshes
  function staleAskFor(sid) { return staleAsks[sid] || null }
  function dismissStaleAsk(sid) {
    var a = staleAsks[sid]
    if (!a) return
    var d = _askDismissed; d[a.id] = true; _askDismissed = d
    var n = staleAsks; delete n[sid]; staleAsks = n; staleAskGen++
  }
  function _publishStaleAsk(sid, open) {
    if (_askDismissed[open.id]) return
    if (staleAsks[sid] && staleAsks[sid].id === open.id) return
    var a = open.arguments || {}
    var n = staleAsks
    n[sid] = { id: open.id, title: a.title || "", message: a.message || "" }
    staleAsks = n; staleAskGen++
  }

  // An unanswered ask_user in the transcript means a turn STOPPED on a question. Surface
  // it only if it is the transcript's final tool call — work after it means the agent
  // moved on and the question no longer needs anyone.
  function _applyRecoveredAsk(sid, open, lastCallId) {
    // Publish only for an IDLE session. While pi streams, an open-looking transcript ask
    // is either genuinely pending — the daemon replays those as ANSWERABLE cards now — or
    // already answered with the toolResult not yet written: the 5s refresh raced a live
    // answer and raised "send your answer to continue" over an agent that was already
    // continuing. Idle + open is the one case the resolver is really gone.
    var live = open && (!lastCallId || open.id === lastCallId) && !isBusy(sid)
    if (!live) {
      // Self-heal a published notice the moment the transcript (or status) moves on —
      // it used to linger until manually dismissed even after the ask was answered.
      if (staleAsks[sid]) { var n = staleAsks; delete n[sid]; staleAsks = n; staleAskGen++ }
      return
    }
    _publishStaleAsk(sid, open)
  }

  // One Socket per scope, each in its own Loader so a re-dial gets a fresh object
  // (wedge recovery, same pattern as PaletteState) without disturbing the others.
  // A tunneled remote (autossh -L …) presents as a local socket, so the rail stays
  // transport-agnostic like the nvim thin client.
  Instantiator {
    model: root.sockPaths
    delegate: Item {
      // Context properties, not `required` ones: Instantiator over a plain JS array
      // doesn't satisfy required-property binding.
      readonly property int idx: index
      readonly property string sockPath: modelData
      Loader {
        id: ld
        active: true
        sourceComponent: Socket {
          path: sockPath
          connected: true
          parser: SplitParser { onRead: data => root.onLine(data, idx) }
          // A dead socket's last roster must not keep claiming "working", but dropping
          // it loses the session AND its cached transcript. Keep the rows, mark them
          // offline (see _rebuildSessions) — context stays, the lie goes.
          onConnectionStateChanged: {
            root._registerSock(idx, ld.item)
            root._rebuildSessions()
          }
        }
        onLoaded: root._registerSock(idx, item)
      }
      Timer {
        interval: 2000; repeat: true
        running: !(ld.item && ld.item.connected)
        onTriggered: { ld.active = false; ld.active = true }
      }
    }
  }
}
