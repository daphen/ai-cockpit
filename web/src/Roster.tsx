import { AnimatePresence } from "motion/react"
import * as m from "motion/react-m"
import type { Session } from "./agentd"
import { sessionKey } from "./agentd"
import { Orb, orbTone } from "./Orb"
import { iconSwap, textSwap } from "./motion"

interface Props {
  sessions: Session[]
  selected: string
  onSelect: (key: string) => void
}

// Remote = the cwd is not under THIS machine's home, same rule the desktop rail uses.
// The marker says which host a session runs on, and it leads the row so every row starts
// on one column.
function isRemote(cwd: string) {
  return /^\/home\/(?!daphen\b)[^/]+\//.test(cwd || "")
}

// Inline SVG, not a text glyph: ▭/☁ rendered as tiny mismatched shapes that read as
// broken. These mirror the rail's cloud/laptop outline markers.
function HostMark({ remote }: { remote: boolean }) {
  return remote ? (
    <svg className="host-mark" viewBox="0 0 18 18" aria-hidden="true">
      <path d="M13.5 14.25H5.25a3.75 3.75 0 0 1-.4-7.48 4.5 4.5 0 0 1 8.42-1.02 3.75 3.75 0 0 1 .23 8.5Z"
            fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
    </svg>
  ) : (
    <svg className="host-mark" viewBox="0 0 18 18" aria-hidden="true">
      <rect x="3.25" y="4" width="11.5" height="8" rx="1.2"
            fill="none" stroke="currentColor" strokeWidth="1.4" />
      <path d="M1.75 14.25h14.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  )
}

export function Roster({ sessions, selected, onSelect }: Props) {
  if (!sessions.length) return <div className="empty">No agent sessions are online.</div>
  return (
    <ol className="roster" aria-label="Agent sessions">
      {sessions.map(session => {
        const key = sessionKey(session.scope, session.name)
        const role = roleName(session.profile)
        const offline = session.status === "offline"
        const working = session.status === "streaming"
        return (
          <li key={key}>
            <button
              type="button"
              className={`session-row ${selected === key ? "selected" : ""}`}
              onClick={() => onSelect(key)}
              aria-label={`${session.displayName ?? session.name} — ${statusLabel(session)}`}
            >
              {session.parent && <span className="linked-mark">↳</span>}
              <HostMark remote={isRemote(session.cwd)} />
              <span className="session-name">{session.displayName ?? session.name}</span>
              {role && <span className="role-badge">{role}</span>}
              <span className="row-spacer" />
              {/* Tool + elapsed is the only status TEXT left — idle/asleep are the dot's
                  job. It fades rather than toggling, so a tool boundary is not a flash. */}
              <span className="tool-word-slot">
                <AnimatePresence initial={false}>
                  {working && session.currentTool && (
                    <m.span className="tool-word on" key={session.currentTool} variants={textSwap} initial="initial" animate="animate" exit="exit">{session.currentTool}</m.span>
                  )}
                </AnimatePresence>
              </span>
              {/* Connection trouble is the only thing that earns an icon, and it sits to
                  the LEFT of the state slot. */}
              <AnimatePresence initial={false}>
                {offline && (
                  <m.svg className="disconnect-mark" key="offline" viewBox="0 0 18 18" aria-hidden="true" variants={iconSwap} initial="initial" animate="animate" exit="exit">
                    <path d="M10.5 1.5 4 10h4l-.5 6.5L14 8h-4l.5-6.5ZM2 2l14 14"
                          fill="none" stroke="currentColor" strokeWidth="1.4"
                          strokeLinecap="round" strokeLinejoin="round" />
                  </m.svg>
                )}
              </AnimatePresence>
              {/* ONE state slot, last in the row: orb = working, pulsing orange = needs
                  input, otherwise a dot in the shared colour vocabulary. */}
              <span className="roster-orb-slot" aria-hidden="true">
                <AnimatePresence initial={false}>
                  <m.span className="roster-state" key={session.ask ? "ask" : working ? `working-${session.currentTool ?? ""}` : session.status} variants={iconSwap} initial="initial" animate="animate" exit="exit">
                    {session.ask
                      ? <span className="status-dot ask" />
                      : working
                        ? <Orb seedKey={session.name} size={20} tone={orbTone(session.currentTool)} />
                        : <span className={`status-dot ${session.status}`} />}
                  </m.span>
                </AnimatePresence>
              </span>
            </button>
          </li>
        )
      })}
    </ol>
  )
}

function statusLabel(session: Session) {
  if (session.ask) return "needs input"
  if (session.status === "streaming") return session.currentTool ? `working · ${session.currentTool}` : "working"
  return session.status
}

function roleName(profile?: string) {
  if (!profile) return ""
  return profile.split("-").at(-1) ?? profile
}
