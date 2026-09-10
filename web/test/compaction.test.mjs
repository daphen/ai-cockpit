import { afterAll, expect, test } from "bun:test"

const originals = Object.fromEntries(["window", "location", "localStorage", "WebSocket", "fetch"].map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]))
const sockets = []
class Socket {
  static OPEN = 1
  static CONNECTING = 0
  readyState = 1
  constructor() { sockets.push(this) }
  send() {}
  close() {}
  receive(message) { this.onmessage({ data: JSON.stringify(message) }) }
}
Object.assign(globalThis, {
  window: { setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {} },
  location: { origin: "https://example.test" },
  localStorage: { getItem: () => null, setItem() {} },
  WebSocket: Socket,
  fetch: async url => new Response(JSON.stringify(["personal"]), { status: String(url).startsWith("https://example.test/") ? 200 : 503 }),
})
afterAll(() => {
  for (const [key, descriptor] of Object.entries(originals)) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor)
    else delete globalThis[key]
  }
})
const { AgentdStore } = await import("../src/agentd.ts")

test("public mobile store preserves exact rollover/compaction wording through the active branch", async () => {
  const store = new AgentdStore()
  await store.connect("fixture-token")
  const socket = sockets.at(-1)
  socket.onopen()
  socket.receive({ type: "roster", sessions: [{ name: "ticket", cwd: "/tmp", status: "idle" }] })
  store.select("personal/ticket")
  const shapes = [
    { fromHook: true },
    { details: { strategy: "deterministic-auto-v3" } },
    { fromHook: false, details: { strategy: "deterministic-auto-v3" } },
    { fromHook: false },
    {},
    { fromHook: "true", details: { strategy: "other" } },
  ]
  const entries = shapes.map((shape, index) => ({ type: "compaction", id: `c${index}`, parentId: index ? `c${index - 1}` : null, ...shape }))
  entries.push({ type: "compaction", id: "excluded-branch", parentId: "c0", fromHook: true })
  socket.receive({ type: "response", command: "get_entries", session: "ticket", data: { entries, leafId: "c5" } })
  const feed = store.getSnapshot().feeds["personal/ticket"]
  expect(feed.map(item => item.text)).toEqual(["context rolled over", "context rolled over", "context rolled over", "context compacted", "context compacted", "context compacted"])
  expect(feed.map(item => item.key)).toEqual(shapes.map((_, index) => `c${index}`))
})
