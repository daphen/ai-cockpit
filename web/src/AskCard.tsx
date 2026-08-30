import { useState } from "react"
import * as m from "motion/react-m"
import type { Ask } from "./agentd"
import { panelSwap } from "./motion"

interface Props {
  ask: Ask
  onAnswer: (response: Record<string, unknown>) => void
}

export function AskCard({ ask, onAnswer }: Props) {
  const [value, setValue] = useState("")
  const userBash = ask.title === "__cockpit_user_bash__"
  const payload = userBash ? parsePayload(ask.message) : null
  const prompt = ask.message || ask.placeholder
  const options = (ask.options ?? []).map(option => typeof option === "string" ? { label: option, value: option } : { label: option.label ?? option.value ?? "option", value: option.value ?? option.label ?? "" })

  return (
    <m.section className="ask-card" aria-label="Agent needs input" variants={panelSwap} initial="initial" animate="animate" exit="exit">
      <span className="ask-kicker">needs your input</span>
      <h2>{userBash ? "Run this command?" : ask.title || "Question"}</h2>
      {payload ? (
        <><pre className="command">{String(payload.command ?? "")}</pre>{payload.reason && <p>{String(payload.reason)}</p>}</>
      ) : prompt ? <p>{prompt}</p> : null}

      {(ask.method === "confirm" || userBash) && (
        <div className="ask-actions">
          <button className="primary" onClick={() => onAnswer({ confirmed: true })}>Approve</button>
          <button onClick={() => onAnswer({ confirmed: false })}>Decline</button>
        </div>
      )}
      {ask.method === "select" && <div className="ask-options">{options.map(option => <button key={option.value} onClick={() => onAnswer({ value: option.value })}>{option.label}</button>)}</div>}
      {(ask.method === "input" || ask.method === "editor") && (
        <form onSubmit={event => { event.preventDefault(); if (value.trim()) onAnswer({ value: value.trim() }) }}>
          {ask.method === "editor" ? <textarea autoFocus value={value} onChange={event => setValue(event.target.value)} /> : <input autoFocus value={value} onChange={event => setValue(event.target.value)} />}
          <button className="primary" disabled={!value.trim()}>Answer</button>
        </form>
      )}
    </m.section>
  )
}

function parsePayload(message?: string) {
  try { return JSON.parse(message ?? "") as Record<string, unknown> } catch { return null }
}
