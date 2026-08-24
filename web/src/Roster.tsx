import type { Session } from "./agentd"
import { sessionKey } from "./agentd"
import { Orb, orbTone } from "./Orb"

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
        const role = roleName(session.profile)
        return (
          <li key={key}>
            <button type="button" className={`session-row ${selected === key ? "selected" : ""}`} onClick={() => onSelect(key)}>
              {session.parent && <span className="linked-mark">↳</span>}
              <span className="session-name">{session.displayName ?? session.name}</span>
              {role && <span className="role-badge">{role}</span>}
              <span className="roster-orb-slot" aria-hidden="true">
                {session.status === "streaming" ? <Orb seedKey={session.name} size={20} tone={orbTone(session.currentTool)} /> : <span className={`status-dot ${session.status}`} />}
              </span>
              <span className="row-spacer" />
              {session.ask ? <span className="needs-input-pill">needs input</span> : <span className="status-word">{labels[session.status] ?? session.status}</span>}
            </button>
          </li>
        )
      })}
    </ol>
  )
}

function roleName(profile?: string) {
  if (!profile) return ""
  return profile.split("-").at(-1) ?? profile
}
