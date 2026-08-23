export type SessionStatus = "idle" | "streaming" | "asleep" | "error" | "offline"

export interface Session {
  id?: string
  name: string
  cwd: string
  status: SessionStatus
  scope: string
  ask?: boolean
  profile?: string
  parent?: string
  idle?: string
  plan?: string
  lastActivity: number
}

export interface Ask {
  id: string
  method: "confirm" | "select" | "input" | "editor"
  title?: string
  message?: string
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
  scope: string
  socket: WebSocket | null
  connected: boolean
  sessions: Session[]
  reconnectTimer?: number
}

export interface Snapshot {
  sessions: Session[]
  feeds: Record<string, FeedItem[]>
  asks: Record<string, Ask>
  connectedScopes: string[]
  queues: Record<string, string[]>
}

const EMPTY: Snapshot = { sessions: [], feeds: {}, asks: {}, connectedScopes: [], queues: {} }

function sessionKey(scope: string, name: string) {
  return `${scope}/${name}`
}

function clip(value: unknown, length = 82) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim()
  return text.length > length ? `${text.slice(0, length - 1)}…` : text
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

function entriesToFeed(entries: Entry[], leafId?: string): FeedItem[] {
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
  chain.reverse()

  const failures = new Set<string>()
  const results = new Map<string, string>()
  for (const entry of chain) {
    if (entry.message?.role !== "toolResult" || !entry.message.toolCallId) continue
    if (entry.message.isError) failures.add(entry.message.toolCallId)
    results.set(entry.message.toolCallId, textContent(entry.message.content))
  }

  const feed: FeedItem[] = []
  for (const [index, entry] of chain.slice(-80).entries()) {
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
      let text = textContent(message.content).replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").trim()
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
    feed.push({ kind: "turn", text: prose.join("\n\n"), thinking: thinking.filter(Boolean), activity, key })
  }
  return feed
}

export class AgentdStore {
  private scopes = new Map<string, ScopeState>()
  private listeners = new Set<() => void>()
  private feeds: Record<string, FeedItem[]> = {}
  private asks: Record<string, Ask> = {}
  private queues: Record<string, string[]> = {}
  private optimistic: Record<string, FeedItem[]> = {}
  private snapshot: Snapshot = EMPTY

  subscribe = (listener: () => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  getSnapshot = () => this.snapshot

  async connect() {
    const response = await fetch("/scopes", { cache: "no-store" })
    if (!response.ok) throw new Error(`scope discovery failed: ${response.status}`)
    const scopes = await response.json() as string[]
    for (const scope of scopes) this.openScope(scope)
    this.publish()
  }

  select(key: string) {
    const { scope, name } = this.parts(key)
    this.sendScope(scope, { type: "get_entries", session: name })
  }

  submit(key: string, text: string) {
    const session = this.snapshot.sessions.find(item => sessionKey(item.scope, item.name) === key)
    if (session?.status === "streaming") this.steer(key, text)
    else this.prompt(key, text)
  }

  prompt(key: string, text: string) {
    this.command(key, { type: "prompt", message: text })
    this.echo(key, text)
  }

  steer(key: string, text: string) {
    this.command(key, { type: "steer", message: text })
    this.echo(key, text, true)
  }

  enqueue(key: string, text: string) {
    const session = this.snapshot.sessions.find(item => sessionKey(item.scope, item.name) === key)
    if (session?.status !== "streaming") return this.prompt(key, text)
    this.queues[key] = [...(this.queues[key] ?? []), text]
    this.publish()
  }

  interrupt(key: string) {
    this.command(key, { type: "abort" })
  }

  answer(key: string, response: Record<string, unknown>) {
    this.command(key, { type: "answer", response })
  }

  private openScope(scope: string) {
    const current = this.scopes.get(scope)
    if (current?.socket?.readyState === WebSocket.OPEN || current?.socket?.readyState === WebSocket.CONNECTING) return
    const protocol = location.protocol === "https:" ? "wss:" : "ws:"
    const socket = new WebSocket(`${protocol}//${location.host}/ws?scope=${encodeURIComponent(scope)}`)
    const state: ScopeState = current ?? { scope, socket: null, connected: false, sessions: [] }
    state.socket = socket
    this.scopes.set(scope, state)
    socket.onopen = () => { state.connected = true; this.publish() }
    socket.onmessage = event => this.onMessage(scope, String(event.data))
    socket.onclose = () => {
      state.connected = false
      state.sessions = state.sessions.map(session => ({ ...session, status: "offline" }))
      this.publish()
      window.clearTimeout(state.reconnectTimer)
      state.reconnectTimer = window.setTimeout(() => this.openScope(scope), 1500)
    }
  }

  private onMessage(scope: string, line: string) {
    let message: Record<string, any>
    try { message = JSON.parse(line) } catch { return }
    const state = this.scopes.get(scope)
    if (!state) return
    if (message.type === "roster") {
      const now = Date.now()
      state.sessions = (message.sessions ?? []).map((session: Session) => ({ ...session, scope, lastActivity: session.lastActivity ?? now }))
      const claimed = new Set(this.allSessions().filter(session => session.ask).map(session => sessionKey(session.scope, session.name)))
      for (const key of Object.keys(this.asks)) if (!claimed.has(key)) delete this.asks[key]
      this.publish()
      return
    }
    const name = String(message.session ?? "")
    if (!name) return
    const key = sessionKey(scope, name)
    const session = state.sessions.find(item => item.name === name)
    if (session) session.lastActivity = Date.now()
    if (message.type === "response" && message.command === "get_entries") {
      const authoritative = entriesToFeed(message.data?.entries ?? [], message.data?.leafId)
      const corpus = authoritative.filter(item => item.kind === "user").map(item => item.text).join("\n")
      this.optimistic[key] = (this.optimistic[key] ?? []).filter(item => item.kind !== "user" || !corpus.includes(item.text))
      this.feeds[key] = [...authoritative, ...(this.optimistic[key] ?? [])]
    } else if (message.type === "extension_ui_request" && ["confirm", "select", "input", "editor"].includes(message.method)) {
      this.asks[key] = message as Ask
    } else if (message.type === "ask_answered") {
      delete this.asks[key]
    } else if (message.type === "error") {
      this.push(key, { kind: "system", text: String(message.error ?? "agentd error"), tone: "error", key: `error-${Date.now()}` })
    } else if (message.type === "tool_execution_start") {
      const args = message.args ?? {}
      this.push(key, { kind: "system", text: toolHint(String(message.toolName ?? "tool"), args), key: `tool-${message.toolCallId ?? Date.now()}` })
    } else if (message.type === "turn_end" || message.type === "agent_end") {
      this.sendScope(scope, { type: "get_entries", session: name })
      if (message.type === "agent_end") this.flushQueue(key)
    }
    this.publish()
  }

  private command(key: string, command: Record<string, unknown>) {
    const { scope, name } = this.parts(key)
    this.sendScope(scope, { ...command, session: name })
  }

  private sendScope(scope: string, command: Record<string, unknown>) {
    const socket = this.scopes.get(scope)?.socket
    if (!socket || socket.readyState !== WebSocket.OPEN) throw new Error(`${scope} is disconnected`)
    socket.send(JSON.stringify(command))
  }

  private echo(key: string, text: string, steered = false) {
    const item: FeedItem = { kind: "user", text, steered, key: `echo-${Date.now()}` }
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

  private allSessions() {
    return [...this.scopes.values()].flatMap(state => state.sessions)
  }

  private publish() {
    this.snapshot = {
      sessions: this.allSessions().sort((a, b) => Number(Boolean(b.ask)) - Number(Boolean(a.ask)) || b.lastActivity - a.lastActivity || a.name.localeCompare(b.name)),
      feeds: { ...this.feeds },
      asks: { ...this.asks },
      queues: { ...this.queues },
      connectedScopes: [...this.scopes.values()].filter(state => state.connected).map(state => state.scope),
    }
    this.listeners.forEach(listener => listener())
  }
}

export const agentd = new AgentdStore()
export { sessionKey }
