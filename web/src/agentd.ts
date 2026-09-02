import { bridgeHosts, hostRank, type BridgeHost } from "./hosts"

export type SessionStatus = "idle" | "streaming" | "asleep" | "error" | "offline"

export interface Session {
  id?: string
  name: string
  displayName?: string
  cwd: string
  status: SessionStatus
  scope: string
  ask?: boolean
  profile?: string
  parent?: string
  idle?: string
  plan?: string
  // The watchdog goal. Handover pins it on exactly ONE orchestrator, which is how the UI
  // knows which host holds the role.
  goal?: string
  lastActivity: number
  hostId?: string
  currentTool?: string
}

export interface Ask {
  id: string
  method: "confirm" | "select" | "input" | "editor"
  title?: string
  message?: string
  placeholder?: string
  options?: Array<string | { label?: string; value?: string }>
}

export type FeedItem =
  | { kind: "user"; text: string; sender?: string; steered?: boolean; key: string }
  | { kind: "turn"; text: string; thinking: string[]; activity: Activity[]; key: string }
  | { kind: "system"; text: string; tone?: "error" | "info"; key: string }

export interface Activity {
  tool: string
  label: string
  detail?: string
  failed?: boolean
}

interface Entry {
  id?: string
  parentId?: string
  type?: string
  customType?: string
  data?: Record<string, unknown>
  message?: {
    role?: string
    content?: ContentBlock[]
    toolCallId?: string
    isError?: boolean
    stopReason?: string
    errorMessage?: string
  }
}

interface ContentBlock {
  type?: string
  text?: string
  thinking?: string
  name?: string
  tool?: string
  id?: string
  arguments?: Record<string, unknown>
  input?: Record<string, unknown>
  result?: unknown
}

interface ScopeState {
  key: string
  host: BridgeHost
  scope: string
  socket: WebSocket | null
  connected: boolean
  sessions: Session[]
  reconnectTimer?: number
  offlineTimer?: number
}

export interface Snapshot {
  sessions: Session[]
  feeds: Record<string, FeedItem[]>
  asks: Record<string, Ask>
  connectedScopes: string[]
  queues: Record<string, string[]>
  orchestratorScope: string
}

const EMPTY: Snapshot = { sessions: [], feeds: {}, asks: {}, connectedScopes: [], queues: {}, orchestratorScope: "" }
const chatLabelsKey = "cockpit.chatLabels"

export class UnauthorizedError extends Error {
  constructor() {
    super("Bridge token required")
    this.name = "UnauthorizedError"
  }
}

function sessionKey(scope: string, name: string) {
  return `${scope}/${name}`
}

function clip(value: unknown, length = 82) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim()
  return text.length > length ? `${text.slice(0, length - 1)}…` : text
}

function displayUserText(text: string) {
  return text.replace(/\[image (\d+)\]\s+@\S+/g, "[image $1]")
}

function storedChatLabels() {
  try { return JSON.parse(localStorage.getItem(chatLabelsKey) ?? "{}") as Record<string, string> } catch { return {} }
}

function chatDisplayName(entries: Entry[]) {
  for (const entry of entries) {
    if (entry.message?.role !== "user") continue
    let text = textContent(entry.message.content).replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").trim()
    if (text.startsWith("⇄ ")) text = text.slice(Math.max(0, text.indexOf("\n") + 1)).trim()
    const original = text
    text = text
      .replace(/\s*(?:Context from another app:|Attached reference images?)[\s\S]*$/i, "")
      .replace(/https?:\/\/\S+/g, "")
      .replace(/\s+/g, " ")
      .trim()
    return clip(text || original, 46)
  }
  return ""
}

function base(path: unknown) {
  const value = String(path ?? "")
  return value.slice(value.lastIndexOf("/") + 1)
}

function toolHint(name: string, args: Record<string, unknown>) {
  if (["read", "edit", "write", "create"].includes(name)) return `${name} ${base(args.path ?? args.file_path)}`.trim()
  if (["bash", "shell"].includes(name)) return `bash ${clip(args.command ?? args.cmd)}`
  if (["grep", "ripgrep", "search_files"].includes(name)) return `grep ${clip(args.pattern ?? args.query)}`
  if (["glob", "find"].includes(name)) return `glob ${clip(args.pattern ?? args.query)}`
  if (name === "agent_send" || name === "agent_steer") return `${name === "agent_send" ? "send" : "steer"} → ${args.agent ?? "?"}`
  if (name === "agent_spawn") return `spawn → ${args.name ?? base(args.dir)}`
  if (name === "agent_read") return `read ← ${args.agent ?? "?"}`
  if (name === "mcp") return `mcp ${[args.server, args.tool ?? (args.search ? `search:${args.search}` : "")].filter(Boolean).join(" ")}`
  return name
}

function textContent(content: ContentBlock[] = []) {
  return content.filter(block => block.type === "text").map(block => String(block.text ?? "")).join("\n").trim()
}

function askAnswer(result: unknown): string {
  if (result == null) return ""
  if (typeof result === "string") {
    try { return askAnswer(JSON.parse(result)) } catch { return result }
  }
  if (typeof result !== "object") return String(result)
  const value = result as Record<string, unknown>
  if (value.cancelled) return "cancelled"
  if (typeof value.confirmed === "boolean") return value.confirmed ? "approved" : "declined"
  if (value.value != null) return String(value.value)
  return ""
}

function entryChain(entries: Entry[], leafId?: string) {
  const byId = new Map(entries.filter(entry => entry.id).map(entry => [entry.id!, entry]))
  const chain: Entry[] = []
  const seen = new Set<string>()
  let cursor = leafId || entries.at(-1)?.id
  while (cursor && byId.has(cursor) && !seen.has(cursor)) {
    seen.add(cursor)
    const entry = byId.get(cursor)!
    chain.push(entry)
    cursor = entry.parentId
  }
  return chain.reverse()
}

function runningTool(entries: Entry[], leafId?: string) {
  const chain = entryChain(entries, leafId)
  const completed = new Set(chain.flatMap(entry => entry.message?.role === "toolResult" && entry.message.toolCallId ? [entry.message.toolCallId] : []))
  for (let entryIndex = chain.length - 1; entryIndex >= 0; entryIndex--) {
    const blocks = chain[entryIndex].message?.content ?? []
    for (let blockIndex = blocks.length - 1; blockIndex >= 0; blockIndex--) {
      const block = blocks[blockIndex]
      if (block.type !== "toolCall" && block.type !== "tool_use") continue
      if (block.id && completed.has(block.id)) continue
      return String(block.name ?? block.tool ?? "tool")
    }
  }
  return ""
}

function entriesToFeed(entries: Entry[], leafId?: string): FeedItem[] {
  const recent = entryChain(entries, leafId).slice(-80)
  const failures = new Set<string>()
  const answerIds = new Set(recent.flatMap(entry => (entry.message?.content ?? []).flatMap(block =>
    (block.type === "toolCall" || block.type === "tool_use") && (block.name ?? block.tool) === "ask_user" && block.id ? [block.id] : []
  )))
  const results = new Map<string, string>()
  for (const entry of recent) {
    if (entry.message?.role !== "toolResult" || !entry.message.toolCallId) continue
    if (entry.message.isError) failures.add(entry.message.toolCallId)
    if (answerIds.has(entry.message.toolCallId)) results.set(entry.message.toolCallId, textContent(entry.message.content))
  }

  const feed: FeedItem[] = []
  for (const [index, entry] of recent.entries()) {
    const key = entry.id ?? `entry-${index}`
    if (entry.type === "compaction") {
      feed.push({ kind: "system", text: "context compacted", key })
      continue
    }
    if (entry.type === "custom" && entry.customType === "cockpit-user-bash-approval") {
      feed.push({ kind: "user", text: `↳ approved — ! ${entry.data?.command ?? "command"}`, key })
      continue
    }
    const message = entry.message
    if (!message || !["user", "assistant"].includes(message.role ?? "")) continue
    if (message.role === "user") {
      let text = displayUserText(textContent(message.content).replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "")).trim()
      let sender = ""
      if (text.startsWith("⇄ ")) {
        const newline = text.indexOf("\n")
        sender = text.slice(2, newline < 0 ? undefined : newline).trim()
        text = newline < 0 ? "" : text.slice(newline + 1).trim()
      }
      if (text || sender) feed.push({ kind: "user", text, sender, key })
      continue
    }

    const activity: Activity[] = []
    const thinking: string[] = []
    const prose: string[] = []
    for (const block of message.content ?? []) {
      if (block.type === "text" && block.text) prose.push(block.text.trim())
      if (block.type === "thinking") thinking.push(String(block.thinking ?? block.text ?? "").trim())
      if (block.type !== "toolCall" && block.type !== "tool_use") continue
      const name = String(block.name ?? block.tool ?? "tool")
      const args = (block.arguments ?? block.input ?? {}) as Record<string, unknown>
      if (name === "ask_user") {
        const answer = askAnswer(block.result ?? (block.id ? results.get(block.id) : ""))
        activity.push({ tool: "ask", label: `❯ ${args.title ?? args.message ?? "question"}${answer ? ` ↳ ${clip(answer)}` : ""}` })
      } else {
        activity.push({
          tool: name,
          label: toolHint(name, args),
          detail: ["bash", "shell"].includes(name) ? String(args.command ?? args.cmd ?? "") : undefined,
          failed: block.id ? failures.has(block.id) : false,
        })
      }
    }
    if (message.stopReason === "aborted") activity.push({ tool: "error", label: "⏹ turn interrupted", failed: true })
    if (message.stopReason === "error" || message.errorMessage) activity.push({ tool: "error", label: `✗ ${message.errorMessage ?? "turn failed"}`, failed: true })
    const text = prose.join("\n\n")
    const previous = feed.at(-1)
    if (previous?.kind === "turn") {
      previous.text = [previous.text, text].filter(Boolean).join("\n\n")
      previous.thinking.push(...thinking.filter(Boolean))
      previous.activity.push(...activity)
    } else {
      feed.push({ kind: "turn", text, thinking: thinking.filter(Boolean), activity, key })
    }
  }
  return feed
}

export class AgentdStore {
  private hosts = bridgeHosts()
  private scopes = new Map<string, ScopeState>()
  private listeners = new Set<() => void>()
  private feeds: Record<string, FeedItem[]> = {}
  private asks: Record<string, Ask> = {}
  private queues: Record<string, string[]> = {}
  private optimistic: Record<string, FeedItem[]> = {}
  private currentTools: Record<string, string> = {}
  private chatLabels = storedChatLabels()
  private labelRequests = new Set<string>()
  private owners: Record<string, string> = {}
  private orchestratorScopes = new Map<string, string>()
  private snapshot: Snapshot = EMPTY
  private token = ""
  private probeTimer = 0
  private resumeTimer = 0
  private selectedKey = ""
  private refreshSelected = false

  subscribe = (listener: () => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  getSnapshot = () => this.snapshot

  async connect(token: string) {
    if (token !== this.token) this.resetConnections()
    this.token = token
    const result = await this.probeHosts()
    window.clearInterval(this.probeTimer)
    this.probeTimer = window.setInterval(() => void this.probeHosts(), 10_000)
    if (!result.connected && result.unauthorized) throw new UnauthorizedError()
    if (!result.connected) throw new Error("No Cockpit bridge is reachable")
  }

  select(key: string) {
    this.selectedKey = key
    this.refreshSelected = false
    for (const feedKey of Object.keys(this.feeds)) if (feedKey !== key) delete this.feeds[feedKey]
    const { name } = this.parts(key)
    this.sendSession(key, { type: "get_entries", session: name })
  }

  resume() {
    if (!this.token) return
    window.clearTimeout(this.resumeTimer)
    this.resumeTimer = window.setTimeout(() => {
      this.refreshSelected = Boolean(this.selectedKey)
      for (const state of this.scopes.values()) {
        window.clearTimeout(state.reconnectTimer)
        window.clearTimeout(state.offlineTimer)
        state.connected = false
        if (state.socket) {
          state.socket.onclose = null
          state.socket.close()
          state.socket = null
        }
        this.openScope(state.host, state.scope)
      }
      void this.probeHosts()
    }, 120)
  }

  async uploadImage(key: string, file: File) {
    const state = this.scopes.get(this.owners[key])
    if (!state?.connected) throw new Error(`${this.parts(key).scope} is disconnected`)
    const response = await fetch(`${state.host.baseUrl}/upload?scope=${encodeURIComponent(state.scope)}`, {
      method: "POST",
      mode: "cors",
      headers: {
        Authorization: `Bearer ${this.token}`,
        "Content-Type": file.type,
      },
      body: file,
    })
    if (!response.ok) throw new Error(response.status === 413 ? "Image exceeds 12 MB" : `Image upload failed (${response.status})`)
    const result = await response.json() as { path?: string }
    if (!result.path) throw new Error("Image upload returned no path")
    return result.path
  }

  labelChats(sessions: Session[]) {
    for (const session of sessions) {
      if (session.scope !== "chat" || session.displayName) continue
      const key = sessionKey(session.scope, session.name)
      if (this.labelRequests.has(key)) continue
      this.labelRequests.add(key)
      try { this.sendSession(key, { type: "get_entries", session: session.name }) } catch { this.labelRequests.delete(key) }
    }
  }

  submit(key: string, text: string) {
    const session = this.snapshot.sessions.find(item => sessionKey(item.scope, item.name) === key)
    if (session?.status === "streaming") this.enqueue(key, text)
    else this.prompt(key, text)
  }

  prompt(key: string, text: string) {
    this.command(key, { type: "prompt", message: text })
    this.echo(key, text)
  }

  steer(key: string, text: string) {
    this.command(key, { type: "steer", message: text })
  }

  enqueue(key: string, text: string) {
    const session = this.snapshot.sessions.find(item => sessionKey(item.scope, item.name) === key)
    if (session?.status !== "streaming") return this.prompt(key, text)
    this.queues[key] = [...(this.queues[key] ?? []), text]
    this.publish()
  }

  steerQueued(key: string, index: number) {
    const queue = this.queues[key] ?? []
    const message = queue[index]
    if (!message) return
    const next = queue.filter((_, itemIndex) => itemIndex !== index)
    if (next.length) this.queues[key] = next
    else delete this.queues[key]
    const session = this.snapshot.sessions.find(item => sessionKey(item.scope, item.name) === key)
    if (session?.status === "streaming") this.steer(key, message)
    else this.prompt(key, message)
    this.publish()
  }

  interrupt(key: string) {
    this.command(key, { type: "abort" })
  }

  answer(key: string, response: Record<string, unknown>) {
    this.command(key, { type: "answer", response })
  }

  private async probeHosts() {
    const results = await Promise.all(this.hosts.map(host => this.probeHost(host)))
    return {
      connected: results.some(result => result === "connected"),
      unauthorized: results.some(result => result === "unauthorized"),
    }
  }

  private async probeHost(host: BridgeHost): Promise<"connected" | "unauthorized" | "offline"> {
    const controller = new AbortController()
    const timeout = window.setTimeout(() => controller.abort(), 5_000)
    try {
      const response = await fetch(`${host.baseUrl}/scopes`, {
        cache: "no-store",
        mode: "cors",
        headers: { Authorization: `Bearer ${this.token}` },
        signal: controller.signal,
      })
      if (response.status === 401) return "unauthorized"
      if (!response.ok) return "offline"
      const holder = response.headers.get("X-Cockpit-Orchestrator") ?? ""
      if (holder === "lovable" || holder === "work") this.orchestratorScopes.set(host.id, holder)
      else this.orchestratorScopes.delete(host.id)
      const scopes = await response.json() as string[]
      this.reconcileHost(host, scopes)
      return "connected"
    } catch {
      this.orchestratorScopes.delete(host.id)
      return "offline"
    } finally {
      window.clearTimeout(timeout)
    }
  }

  private reconcileHost(host: BridgeHost, scopes: string[]) {
    const wanted = new Set(scopes.map(scope => this.scopeStateKey(host.id, scope)))
    let removed = false
    for (const [key, state] of this.scopes) {
      if (state.host.id !== host.id || wanted.has(key)) continue
      this.removeScope(key)
      removed = true
    }
    for (const scope of scopes) this.openScope(host, scope)
    if (removed) this.publish()
  }

  private openScope(host: BridgeHost, scope: string) {
    const key = this.scopeStateKey(host.id, scope)
    const current = this.scopes.get(key)
    if (current?.socket?.readyState === WebSocket.OPEN || current?.socket?.readyState === WebSocket.CONNECTING) return
    const base = new URL(host.baseUrl)
    const protocol = base.protocol === "https:" ? "wss:" : "ws:"
    const query = new URLSearchParams({ scope, token: this.token })
    const socket = new WebSocket(`${protocol}//${base.host}/ws?${query}`)
    const state: ScopeState = current ?? { key, host, scope, socket: null, connected: false, sessions: [] }
    window.clearTimeout(state.reconnectTimer)
    state.socket = socket
    this.scopes.set(key, state)
    socket.onopen = () => {
      if (state.socket !== socket) return
      window.clearTimeout(state.offlineTimer)
      state.connected = true
      this.publish()
    }
    socket.onmessage = event => {
      if (state.socket === socket) this.onMessage(key, String(event.data))
    }
    socket.onclose = () => {
      if (state.socket !== socket) return
      state.socket = null
      state.connected = false
      if (this.owners[this.selectedKey] === key) this.refreshSelected = true
      window.clearTimeout(state.reconnectTimer)
      state.reconnectTimer = window.setTimeout(() => this.openScope(host, scope), 250)
      window.clearTimeout(state.offlineTimer)
      state.offlineTimer = window.setTimeout(() => {
        if (state.connected) return
        state.sessions = state.sessions.map(session => ({ ...session, status: "offline" }))
        this.publish()
      }, 8_000)
    }
  }

  private removeScope(key: string) {
    const state = this.scopes.get(key)
    if (!state) return
    window.clearTimeout(state.reconnectTimer)
    window.clearTimeout(state.offlineTimer)
    if (state.socket) {
      state.socket.onclose = null
      state.socket.close()
    }
    this.scopes.delete(key)
  }

  private resetConnections() {
    window.clearInterval(this.probeTimer)
    window.clearTimeout(this.resumeTimer)
    this.selectedKey = ""
    this.refreshSelected = false
    for (const key of [...this.scopes.keys()]) this.removeScope(key)
    this.feeds = {}
    this.asks = {}
    this.queues = {}
    this.optimistic = {}
    this.currentTools = {}
    this.labelRequests.clear()
    this.owners = {}
    this.snapshot = EMPTY
    this.listeners.forEach(listener => listener())
  }

  private onMessage(stateKey: string, line: string) {
    let message: Record<string, any>
    try { message = JSON.parse(line) } catch { return }
    const state = this.scopes.get(stateKey)
    if (!state) return
    const scope = state.scope
    if (message.type === "roster") {
      const now = Date.now()
      state.sessions = (message.sessions ?? []).map((session: Session) => ({
        ...session,
        scope,
        hostId: state.host.id,
        displayName: scope === "chat" ? this.chatLabels[session.name] : session.displayName,
        currentTool: this.currentTools[sessionKey(scope, session.name)],
        lastActivity: session.lastActivity ?? now,
      }))
      this.publish()
      if (this.refreshSelected && this.owners[this.selectedKey] === stateKey) {
        const { name: selectedName } = this.parts(this.selectedKey)
        try {
          this.sendSession(this.selectedKey, { type: "get_entries", session: selectedName })
          this.refreshSelected = false
        } catch {}
      }
      const claimed = new Set(this.snapshot.sessions.filter(session => session.ask).map(session => sessionKey(session.scope, session.name)))
      for (const key of Object.keys(this.asks)) if (!claimed.has(key)) delete this.asks[key]
      return
    }
    const name = String(message.session ?? "")
    if (!name) return
    const key = sessionKey(scope, name)
    if (this.owners[key] !== stateKey) return
    const session = state.sessions.find(item => item.name === name)
    const labelRequest = message.type === "response" && message.command === "get_entries" && this.labelRequests.delete(key)
    if (session && !labelRequest) session.lastActivity = Date.now()
    if (message.type === "response" && message.command === "get_entries") {
      const entries = (message.data?.entries ?? []) as Entry[]
      if (scope === "chat") {
        const displayName = chatDisplayName(entries)
        if (displayName) {
          this.chatLabels[name] = displayName
          if (session) session.displayName = displayName
          try { localStorage.setItem(chatLabelsKey, JSON.stringify(this.chatLabels)) } catch {}
        }
      }
      if (!labelRequest && key === this.selectedKey) {
        const tool = session?.status === "streaming" ? runningTool(entries, message.data?.leafId) : ""
        if (tool) this.currentTools[key] = tool
        else delete this.currentTools[key]
        if (session) session.currentTool = tool || undefined
        const authoritative = entriesToFeed(entries, message.data?.leafId)
        const corpus = authoritative.filter(item => item.kind === "user").map(item => item.text).join("\n")
        this.optimistic[key] = (this.optimistic[key] ?? []).filter(item => item.kind !== "user" || (!item.steered && !corpus.includes(item.text)))
        this.feeds[key] = [...authoritative, ...(this.optimistic[key] ?? [])]
      }
    } else if (message.type === "extension_ui_request" && ["confirm", "select", "input", "editor"].includes(message.method)) {
      this.asks[key] = message as Ask
    } else if (message.type === "ask_answered") {
      delete this.asks[key]
    } else if (message.type === "error") {
      if (key === this.selectedKey) this.push(key, { kind: "system", text: String(message.error ?? "agentd error"), tone: "error", key: `error-${Date.now()}` })
    } else if (message.type === "tool_execution_start") {
      const args = message.args ?? {}
      this.currentTools[key] = String(message.toolName ?? "tool")
      if (session) session.currentTool = this.currentTools[key]
      if (key === this.selectedKey) this.push(key, { kind: "system", text: toolHint(this.currentTools[key], args), key: `tool-${message.toolCallId ?? Date.now()}` })
    } else if (message.type === "tool_execution_end") {
      delete this.currentTools[key]
      if (session) session.currentTool = undefined
    } else if (message.type === "turn_end" || message.type === "agent_end") {
      delete this.currentTools[key]
      if (session) session.currentTool = undefined
      if (key === this.selectedKey) this.sendSession(key, { type: "get_entries", session: name })
      if (message.type === "agent_end") this.flushQueue(key)
    }
    this.publish()
  }

  private command(key: string, command: Record<string, unknown>) {
    const { name } = this.parts(key)
    this.sendSession(key, { ...command, session: name })
  }

  private sendSession(key: string, command: Record<string, unknown>) {
    const state = this.scopes.get(this.owners[key])
    const socket = state?.socket
    if (!state || !socket || socket.readyState !== WebSocket.OPEN) throw new Error(`${this.parts(key).scope} is disconnected`)
    socket.send(JSON.stringify(command))
  }

  private echo(key: string, text: string, steered = false) {
    const item: FeedItem = { kind: "user", text: displayUserText(text), steered, key: `echo-${Date.now()}` }
    this.optimistic[key] = [...(this.optimistic[key] ?? []), item]
    this.feeds[key] = [...(this.feeds[key] ?? []), item]
    this.publish()
  }

  private push(key: string, item: FeedItem) {
    this.feeds[key] = [...(this.feeds[key] ?? []), item].slice(-240)
  }

  private flushQueue(key: string) {
    const queue = this.queues[key] ?? []
    if (!queue.length) return
    const [next, ...rest] = queue
    if (rest.length) this.queues[key] = rest
    else delete this.queues[key]
    this.prompt(key, next)
  }

  private parts(key: string) {
    const split = key.indexOf("/")
    return { scope: key.slice(0, split), name: key.slice(split + 1) }
  }

  private scopeStateKey(hostId: string, scope: string) {
    return `${hostId}|${scope}`
  }

  private selectedSessions() {
    const candidates = new Map<string, Array<{ state: ScopeState; session: Session }>>()
    for (const state of this.scopes.values()) {
      for (const session of state.sessions) {
        const key = sessionKey(session.scope, session.name)
        const list = candidates.get(key) ?? []
        list.push({ state, session })
        candidates.set(key, list)
      }
    }
    this.owners = {}
    const selected: Session[] = []
    for (const [key, list] of candidates) {
      list.sort((a, b) => Number(!a.state.connected) - Number(!b.state.connected) || hostRank(a.state.host, a.session.scope) - hostRank(b.state.host, b.session.scope))
      const winner = list[0]
      this.owners[key] = winner.state.key
      selected.push(winner.session)
    }
    return selected
  }

  private publish() {
    // STABLE order: name only. Sorting by recency reshuffled the list every time a
    // session emitted an event, so rows swapped places under your thumb mid-read and the
    // status dots jumped (David, 2026-08-25). Matches the desktop rail.
    const sessions = this.selectedSessions().sort((a, b) => a.name.localeCompare(b.name))
    this.snapshot = {
      sessions,
      feeds: { ...this.feeds },
      asks: { ...this.asks },
      queues: { ...this.queues },
      connectedScopes: [...new Set([...this.scopes.values()].filter(scope => scope.connected).map(scope => scope.scope))],
      orchestratorScope: this.orchestratorScopes.get("proart") ?? "",
    }
    this.listeners.forEach(listener => listener())
  }
}

export const agentd = new AgentdStore()
export { sessionKey }
