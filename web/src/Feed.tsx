import { useEffect, useRef } from "react"
import type { FeedItem } from "./agentd"

export function Feed({ items }: { items: FeedItem[] }) {
  const end = useRef<HTMLDivElement>(null)
  useEffect(() => end.current?.scrollIntoView({ block: "end" }), [items])

  if (!items.length) return <div className="empty feed-empty">Select a session to load its conversation.</div>
  return (
    <div className="feed" aria-live="polite">
      {items.map(item => {
        if (item.kind === "user") return (
          <article className="message user-message" key={item.key}>
            <header>{item.sender ? `from ${item.sender}` : item.steered ? "you · steered" : "you"}</header>
            <p>{item.text}</p>
          </article>
        )
        if (item.kind === "system") return <div className={`system-row ${item.tone ?? ""}`} key={item.key}>{item.text}</div>
        return (
          <article className="message agent-message" key={item.key}>
            <header>agent</header>
            {item.thinking.map((thought, index) => (
              <details className="thinking" key={index}><summary>thinking</summary><pre>{thought}</pre></details>
            ))}
            {item.text && <div className="prose">{item.text}</div>}
            {!!item.activity.length && (
              <details className="activity">
                <summary>{activitySummary(item.activity)}</summary>
                <ol>
                  {item.activity.map((activity, index) => (
                    <li className={activity.failed ? "failed" : ""} key={`${activity.label}-${index}`}>
                      <span>{activity.label}</span>
                      {activity.detail && <pre>{activity.detail}</pre>}
                    </li>
                  ))}
                </ol>
              </details>
            )}
          </article>
        )
      })}
      <div ref={end} />
    </div>
  )
}

function activitySummary(items: Extract<FeedItem, { kind: "turn" }>["activity"]) {
  const errors = items.filter(item => item.failed).length
  const edits = items.filter(item => ["edit", "write", "create"].includes(item.tool)).length
  const parts = [`${items.length} tool${items.length === 1 ? "" : "s"}`]
  if (edits) parts.push(`${edits} edited`)
  if (errors) parts.push(`${errors} failed`)
  return parts.join(" · ")
}
