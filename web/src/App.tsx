import { useEffect, useMemo, useState, useSyncExternalStore } from "react"
import { AnimatePresence, domAnimation, LazyMotion, MotionConfig } from "motion/react"
import * as m from "motion/react-m"
import { agentd, sessionKey, UnauthorizedError } from "./agentd"
import { AskCard } from "./AskCard"
import { Composer } from "./Composer"
import { Feed } from "./Feed"
import { LoadingIndicator } from "./LoadingIndicator"
import { Roster } from "./Roster"

const tokenKey = "cockpit.bridgeToken"
type CockpitGroup = "work" | "private"
const groupScopes: Record<CockpitGroup, Set<string>> = {
  work: new Set(["lovable", "work"]),
  private: new Set(["personal", "chat"]),
}

export default function App() {
  const state = useSyncExternalStore(agentd.subscribe, agentd.getSnapshot)
  const [selected, setSelected] = useState("")
  const [group, setGroup] = useState<CockpitGroup>("work")
  const [scope, setScope] = useState("all")
  const [rosterExpanded, setRosterExpanded] = useState(false)
  const [updateReady, setUpdateReady] = useState(false)
  const [error, setError] = useState("")
  const [token, setToken] = useState(() => localStorage.getItem(tokenKey) ?? "")
  const [needsToken, setNeedsToken] = useState(!token)
  const [checkingToken, setCheckingToken] = useState(Boolean(token))

  useEffect(() => {
    if (!token) return
    let current = true
    setCheckingToken(true)
    agentd.connect(token).then(() => {
      if (!current) return
      setError("")
      setNeedsToken(false)
      setCheckingToken(false)
    }).catch(cause => {
      if (!current) return
      setCheckingToken(false)
      if (cause instanceof UnauthorizedError) {
        localStorage.removeItem(tokenKey)
        setToken("")
        setNeedsToken(true)
        setError("That bridge token was rejected.")
        return
      }
      setNeedsToken(false)
      setError(String(cause))
    })
    return () => { current = false }
  }, [token])
  useEffect(() => {
    const ready = () => setUpdateReady(true)
    window.addEventListener("cockpit:update-ready", ready)
    return () => window.removeEventListener("cockpit:update-ready", ready)
  }, [])
  useEffect(() => {
    if (needsToken || checkingToken) return
    const resume = () => {
      if (document.visibilityState === "visible") agentd.resume()
    }
    document.addEventListener("visibilitychange", resume)
    window.addEventListener("pageshow", resume)
    window.addEventListener("online", resume)
    window.addEventListener("focus", resume)
    return () => {
      document.removeEventListener("visibilitychange", resume)
      window.removeEventListener("pageshow", resume)
      window.removeEventListener("online", resume)
      window.removeEventListener("focus", resume)
    }
  }, [checkingToken, needsToken])
  const groupSessions = useMemo(() => state.sessions.filter(session => groupScopes[group].has(session.scope)), [group, state.sessions])
  const visibleSessions = useMemo(() => scope === "all" ? groupSessions : groupSessions.filter(session => session.scope === scope), [groupSessions, scope])
  useEffect(() => {
    if (selected && state.sessions.some(session => sessionKey(session.scope, session.name) === selected)) return
    const first = visibleSessions[0]
    setSelected(first ? sessionKey(first.scope, first.name) : "")
  }, [selected, state.sessions, visibleSessions])
  useEffect(() => { if (selected) agentd.select(selected) }, [selected])
  useEffect(() => { if (scope === "chat") agentd.labelChats(visibleSessions) }, [scope, visibleSessions])

  const active = state.sessions.find(session => sessionKey(session.scope, session.name) === selected)
  const scopes = useMemo(() => [...new Set(groupSessions.map(session => session.scope))], [groupSessions])
  const ask = selected ? state.asks[selected] : undefined
  const run = (action: () => void) => { try { setError(""); action() } catch (cause) { setError(String(cause)) } }
  const saveToken = (next: string) => {
    localStorage.setItem(tokenKey, next)
    setError("")
    setNeedsToken(false)
    setToken(next)
  }
  const chooseGroup = (next: CockpitGroup) => {
    setGroup(next)
    setScope(next === "private" ? "personal" : "all")
  }
  const chooseScope = (next: string) => setScope(next)
  const loadingCockpit = !error && !state.connectedScopes.length && !state.sessions.length

  return (
    <MotionConfig reducedMotion="user">
      <LazyMotion features={domAnimation} strict>
        {checkingToken || (!needsToken && loadingCockpit) ? (
          <Splash label={checkingToken ? "connecting bridges" : "loading rosters"} />
        ) : needsToken ? (
          <TokenLogin checking={false} error={error} onSubmit={saveToken} />
        ) : (
          <main className={`app ${active ? "session-open" : ""}`}>
            <aside className="roster-pane">
              <header className="app-header"><div><span>cockpit</span><strong>{group}</strong></div><small>{groupSessions.length} agents</small></header>
              <nav className="group-tabs" aria-label="Cockpit group">
                {(["work", "private"] as CockpitGroup[]).map(item => (
                  <button className={group === item ? "active" : ""} key={item} onClick={() => chooseGroup(item)}>{item}</button>
                ))}
              </nav>
              <nav className="scope-tabs" aria-label={`${group} scope filter`}>
                {["all", ...scopes].map(item => <button className={scope === item ? "active" : ""} key={item} onClick={() => chooseScope(item)}>{item}</button>)}
              </nav>
              <Roster sessions={visibleSessions} selected={selected} onSelect={setSelected} />
            </aside>

            <div className="session-stage">
            <AnimatePresence initial={false}>
              <m.section
                className="session-pane"
                key={selected || "empty"}
                initial={{ opacity: 0, transform: "translateX(8px)" }}
                animate={{ opacity: 1, transform: "translateX(0px)" }}
                exit={{ opacity: 0, transform: "translateX(-8px)" }}
                transition={{ duration: 0.25, ease: [0.22, 1, 0.36, 1] }}
              >
                {active ? (
                  <>
                    <header className="session-header">
                      <button className="back" onClick={() => setRosterExpanded(true)} aria-label="Open roster">←</button>
                      <div><strong>{active.displayName ?? active.name}</strong><span>{active.scope} · {active.status}</span></div>
                      {active.plan && <span className="plan-chip">{active.plan}</span>}
                    </header>
                    {error && <div className="error-banner">{error}</div>}
                    <Feed items={state.feeds[selected]} />
                    {ask && <AskCard ask={ask} onAnswer={response => run(() => agentd.answer(selected, response))} />}
                    <Composer
                      sessionName={active.displayName ?? active.name}
                      currentTool={active.currentTool}
                      fleet={visibleSessions.filter(session => session.scope !== "chat" && sessionKey(session.scope, session.name) !== selected)}
                      busy={active.status === "streaming"}
                      queue={state.queues[selected] ?? []}
                      disabled={Boolean(ask)}
                      onSubmit={text => run(() => agentd.submit(selected, text))}
                      onSteerQueued={index => run(() => agentd.steerQueued(selected, index))}
                      onInterrupt={() => run(() => agentd.interrupt(selected))}
                      rosterExpanded={rosterExpanded}
                      onRosterExpandedChange={setRosterExpanded}
                      rosterKey={`${group}/${scope}`}
                      rosterHeader={(
                        <nav className="group-tabs" aria-label="Cockpit group">
                          {(["work", "private"] as CockpitGroup[]).map(item => <button type="button" className={group === item ? "active" : ""} key={item} onClick={() => chooseGroup(item)}>{item}</button>)}
                        </nav>
                      )}
                      roster={(
                        <>
                          <nav className="scope-tabs" aria-label={`${group} scope filter`}>
                            {["all", ...scopes].map(item => <button type="button" className={scope === item ? "active" : ""} key={item} onClick={() => chooseScope(item)}>{item}</button>)}
                          </nav>
                          <Roster sessions={visibleSessions.filter(session => sessionKey(session.scope, session.name) !== selected)} selected={selected} onSelect={key => { setSelected(key); setRosterExpanded(false) }} />
                        </>
                      )}
                    />
                  </>
                ) : (
                  <div className="desktop-empty"><strong>Pick an agent</strong><span>Its live conversation will open here.</span></div>
                )}
              </m.section>
            </AnimatePresence>
            </div>
            {error && !active && <div className="error-banner global">{error}</div>}
          </main>
        )}
        {updateReady && (
          <div className="update-toast" role="status">
            <span>new cockpit ready</span>
            <button onClick={() => window.dispatchEvent(new Event("cockpit:apply-update"))}>update & reload</button>
          </div>
        )}
      </LazyMotion>
    </MotionConfig>
  )
}

function Splash({ label }: { label: string }) {
  return (
    <m.main className="boot-splash" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.15 }}>
      <LoadingIndicator label={label} />
    </m.main>
  )
}

function TokenLogin({ checking, error, onSubmit }: { checking: boolean; error: string; onSubmit: (token: string) => void }) {
  const [value, setValue] = useState("")
  const valid = /^[0-9a-f]{64}$/.test(value)
  return (
    <main className="token-shell">
      <m.form
        className="token-card"
        initial={{ opacity: 0, transform: "translateY(8px)" }}
        animate={{ opacity: 1, transform: "translateY(0px)" }}
        onSubmit={event => { event.preventDefault(); if (valid) onSubmit(value) }}
      >
        <span>cockpit</span>
        <h1>{checking ? "Connecting…" : "Bridge token"}</h1>
        {checking ? <p>Authenticating this device with the bridge.</p> : (
          <>
            <p>Enter the private token for this Cockpit origin. It stays on this device.</p>
            <input
              type="password"
              aria-label="Bridge token"
              autoComplete="off"
              autoCapitalize="none"
              spellCheck={false}
              value={value}
              onChange={event => setValue(event.target.value.trim())}
              autoFocus
            />
            {error && <div className="token-error">{error}</div>}
            <button className="primary" disabled={!valid}>Connect</button>
          </>
        )}
      </m.form>
    </main>
  )
}
