import type { Session } from "./agentd"
import { sessionKey } from "./agentd"

interface Props {
  sessions: Session[]
  selected: string
  onSelect: (key: string) => void
}

const labels: Record<string, string> = { streaming: "working", asleep: "asleep", offline: "offline", error: "error", idle: "idle" }

export function Roster({ sessions, selected, onSelect }: Props) {
  if (!sessions.length) return <div className="empty">No agent sessions are online.</div>
  return (
    <ol className="roster" aria-label="Agent sessions">
      {sessions.map(session => {
        const key = sessionKey(session.scope, session.name)
        return (
          <li key={key}>
            <button className={`session-row ${selected === key ? "selected" : ""}`} onClick={() => onSelect(key)}>
              <span className={`status-dot ${session.status}`} aria-hidden="true" />
              <span className="session-copy">
                <strong>{session.name}</strong>
                <span>{labels[session.status] ?? session.status}{session.profile ? ` · ${session.profile.replace("lovable-", "")}` : ""}</span>
              </span>
              <span className="scope-badge">{session.scope}</span>
              <span className="t-badge" data-open={session.ask ? "true" : "false"} aria-label={session.ask ? "Needs input" : undefined} aria-hidden={!session.ask}>
                <span className="t-badge-dot needs-input">!</span>
              </span>
            </button>
          </li>
        )
      })}
    </ol>
  )
}
