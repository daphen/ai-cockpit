import { useEffect, useRef } from "react"
import type { Activity, FeedItem } from "./agentd"
import { LoadingIndicator } from "./LoadingIndicator"
import { MessageIcon } from "./MessageIcon"

export function Feed({ items }: { items?: FeedItem[] }) {
  const feed = useRef<HTMLDivElement>(null)
  const end = useRef<HTMLDivElement>(null)
  const following = useRef(true)
  const loaded = items !== undefined
  const rows = items ?? []
  useEffect(() => {
    if (following.current) end.current?.scrollIntoView({ block: "end" })
  }, [items])

  return (
    <div className={`feed-stage t-skel ${loaded ? "is-revealed" : ""}`} aria-busy={!loaded}>
      <div className="feed-loader t-skel-skeleton" aria-hidden={loaded}>
        <LoadingIndicator label="loading messages" />
      </div>
      <div
        className="feed t-skel-content"
        ref={feed}
        aria-live="polite"
        onScroll={() => {
        const node = feed.current
        if (node) following.current = node.scrollHeight - node.scrollTop - node.clientHeight < 80
      }}
    >
      {!rows.length && <div className="empty feed-empty">No messages yet. Start the conversation below.</div>}
      {rows.map(item => {
        if (item.kind === "user") return (
          <article className="turn-card user-turn" key={item.key}>
            <header className="turn-header">
              <MessageIcon sender="user" />
              <strong>{item.sender ? `⇄ ${item.sender}` : "you"}</strong>
              {item.steered && <span className="steer-cap">steer</span>}
            </header>
            <p className="turn-copy">{item.text}</p>
          </article>
        )
        if (item.kind === "system") return (
          <article className={`turn-card system-turn ${item.tone ?? ""}`} key={item.key}>
            <p>· {item.text.replace(/^·\s*/, "")}</p>
          </article>
        )
        const outcome = !item.text
          ? item.activity.length
            ? `· turn ended without a summary — ${item.activity.length} tool call${item.activity.length === 1 ? "" : "s"}`
            : "· turn ended without visible output"
          : ""
        return (
          <article className="turn-card agent-turn" key={item.key}>
            <header className="turn-header"><MessageIcon sender="agent" /><strong>agent</strong></header>
            {item.thinking.map((thought, index) => (
              <details className="thinking-row" key={index}>
                <summary><span className="thinking-dot" />{firstLine(thought)}</summary>
                <pre>{thought}</pre>
              </details>
            ))}
            {item.text && <div className="turn-copy agent-copy">{item.text}</div>}
            {outcome && <p className="outcome-note">{outcome}</p>}
            {!!item.activity.length && <ActivityDisclosure items={item.activity} />}
          </article>
        )
      })}
        <div className="feed-end-spacer" ref={end} aria-hidden="true" />
      </div>
    </div>
  )
}

function ActivityDisclosure({ items }: { items: Activity[] }) {
  return (
    <details className="activity-row">
      <summary><span className="disclosure-glyph">&gt;</span>{activitySummary(items)}</summary>
      <ol>
        {items.map((activity, index) => (
          <li className={activity.failed ? "failed" : ""} key={`${activity.label}-${index}`}>
            <span className="tool-glyph">{toolGlyph(activity.tool)}</span>
            <span className="tool-line">{activity.label}{activity.failed ? " — failed" : ""}</span>
            {activity.detail && <pre>{activity.detail}</pre>}
          </li>
        ))}
      </ol>
    </details>
  )
}

function activitySummary(items: Activity[]) {
  const counts = new Map<string, number>()
  let edits = 0
  let errors = 0
  for (const item of items) {
    if (["edit", "write", "create", "str_replace"].includes(item.tool)) edits++
    else if (item.tool === "error") errors++
    else counts.set(item.tool, (counts.get(item.tool) ?? 0) + 1)
    if (item.failed && item.tool !== "error") errors++
  }
  const parts = [...counts].map(([tool, count]) => `${count} ${tool}`)
  if (edits) parts.push(`edited ${edits}`)
  if (errors) parts.push(`${errors} error${errors === 1 ? "" : "s"}`)
  return parts.join(" · ")
}

function toolGlyph(tool: string) {
  if (["bash", "shell"].includes(tool)) return "›"
  if (["edit", "write", "create", "str_replace"].includes(tool)) return "✎"
  return "⚙"
}

function firstLine(text: string) {
  const line = text.split("\n", 1)[0].replace(/\s+/g, " ").trim()
  return line.length > 90 ? `${line.slice(0, 89)}…` : line || "thinking"
}
