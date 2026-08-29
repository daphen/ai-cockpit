import { useEffect, useLayoutEffect, useRef } from "react"
import { AnimatePresence } from "motion/react"
import * as m from "motion/react-m"
import type { Activity, FeedItem } from "./agentd"
import { LoadingIndicator } from "./LoadingIndicator"
import { MessageIcon } from "./MessageIcon"
import { iconSwap, textSwap } from "./motion"

export function Feed({ items, pinToEnd = false }: { items?: FeedItem[]; pinToEnd?: boolean }) {
  const feed = useRef<HTMLDivElement>(null)
  const following = useRef(true)
  const loaded = items !== undefined
  const rows = items ?? []
  const scrollToEnd = () => {
    const node = feed.current
    if (node) node.scrollTop = node.scrollHeight
  }
  useLayoutEffect(() => {
    if (following.current) scrollToEnd()
  }, [items])
  useLayoutEffect(() => {
    if (!pinToEnd) return
    following.current = true
    scrollToEnd()
    requestAnimationFrame(scrollToEnd)
  }, [pinToEnd])
  useEffect(() => {
    const messageSent = () => {
      following.current = true
      requestAnimationFrame(scrollToEnd)
    }
    const viewportChanged = (event: Event) => {
      const keyboardOpen = Boolean((event as CustomEvent<{ keyboardOpen?: boolean }>).detail?.keyboardOpen)
      if (!following.current && !keyboardOpen) return
      following.current = true
      requestAnimationFrame(scrollToEnd)
    }
    window.addEventListener("cockpit:message-sent", messageSent)
    window.addEventListener("cockpit:viewport-change", viewportChanged)
    return () => {
      window.removeEventListener("cockpit:message-sent", messageSent)
      window.removeEventListener("cockpit:viewport-change", viewportChanged)
    }
  }, [])

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
      <AnimatePresence initial={false}>
        {!rows.length && <m.div className="empty feed-empty" key="empty" variants={textSwap} initial="initial" animate="animate" exit="exit">No messages yet. Start the conversation below.</m.div>}
      </AnimatePresence>
      {rows.map(item => {
        if (item.kind === "user") return (
          <m.article className="turn-card user-turn" key={item.key} variants={iconSwap} initial="initial" animate="animate">
            <header className="turn-header">
              <MessageIcon sender="user" />
              <strong>{item.sender ? `⇄ ${item.sender}` : "you"}</strong>
              {item.steered && <m.span className="steer-cap" variants={textSwap} initial="initial" animate="animate">steer</m.span>}
            </header>
            <p className="turn-copy">{item.text}</p>
          </m.article>
        )
        if (item.kind === "system") return (
          <m.article className={`turn-card system-turn ${item.tone ?? ""}`} key={item.key} variants={textSwap} initial="initial" animate="animate">
            <p>· {item.text.replace(/^·\s*/, "")}</p>
          </m.article>
        )
        const outcome = !item.text
          ? item.activity.length
            ? `· turn ended without a summary — ${item.activity.length} tool call${item.activity.length === 1 ? "" : "s"}`
            : "· turn ended without visible output"
          : ""
        return (
          <m.article className="turn-card agent-turn" key={item.key} variants={iconSwap} initial="initial" animate="animate">
            <header className="turn-header"><MessageIcon sender="agent" /><strong>agent</strong></header>
            {item.thinking.map((thought, index) => (
              <details className="thinking-row" key={index}>
                <summary><span className="thinking-dot" />{firstLine(thought)}</summary>
                <pre>{thought}</pre>
              </details>
            ))}
            {item.text && <div className="turn-copy agent-copy">{item.text}</div>}
            <AnimatePresence initial={false}>
              {outcome && <m.p className="outcome-note" key={outcome} variants={textSwap} initial="initial" animate="animate" exit="exit">{outcome}</m.p>}
            </AnimatePresence>
            {!!item.activity.length && <ActivityDisclosure items={item.activity} />}
          </m.article>
        )
      })}
        <div className="feed-end-spacer" aria-hidden="true" />
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
