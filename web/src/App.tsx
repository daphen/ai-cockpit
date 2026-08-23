import { useEffect, useMemo, useState, useSyncExternalStore } from "react"
import { AnimatePresence, domAnimation, LazyMotion, MotionConfig } from "motion/react"
import * as m from "motion/react-m"
import { agentd, sessionKey, UnauthorizedError } from "./agentd"
import { AskCard } from "./AskCard"
import { Composer } from "./Composer"
import { Feed } from "./Feed"
import { Roster } from "./Roster"

const tokenKey = "cockpit.bridgeToken"

export default function App() {
  const state = useSyncExternalStore(agentd.subscribe, agentd.getSnapshot)
  const [selected, setSelected] = useState("")
  const [scope, setScope] = useState("all")
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
    if (selected && !state.sessions.some(session => sessionKey(session.scope, session.name) === selected)) setSelected("")
  }, [selected, state.sessions])
  useEffect(() => { if (selected) agentd.select(selected) }, [selected])

  const active = state.sessions.find(session => sessionKey(session.scope, session.name) === selected)
  const scopes = useMemo(() => [...new Set(state.sessions.map(session => session.scope))], [state.sessions])
  const visibleSessions = scope === "all" ? state.sessions : state.sessions.filter(session => session.scope === scope)
  const ask = selected ? state.asks[selected] : undefined
  const run = (action: () => void) => { try { setError(""); action() } catch (cause) { setError(String(cause)) } }
  const saveToken = (next: string) => {
    localStorage.setItem(tokenKey, next)
    setError("")
    setNeedsToken(false)
    setToken(next)
  }

  return (
    <MotionConfig reducedMotion="user">
      <LazyMotion features={domAnimation} strict>
        {needsToken || checkingToken ? (
          <TokenLogin checking={checkingToken} error={error} onSubmit={saveToken} />
        ) : (
          <main className={`app ${active ? "session-open" : ""}`}>
            <aside className="roster-pane">
              <header className="app-header"><div><span>cockpit</span><strong>agents</strong></div><small>{state.connectedScopes.length} scopes online</small></header>
              <nav className="scope-tabs" aria-label="Scope filter">
                {["all", ...scopes].map(item => <button className={scope === item ? "active" : ""} key={item} onClick={() => setScope(item)}>{item}</button>)}
              </nav>
              <Roster sessions={visibleSessions} selected={selected} onSelect={setSelected} />
            </aside>

            <AnimatePresence mode="wait" initial={false}>
              <m.section
                className="session-pane"
                key={selected || "empty"}
                initial={{ opacity: 0, transform: "translateX(8px)", filter: "blur(3px)" }}
                animate={{ opacity: 1, transform: "translateX(0px)", filter: "blur(0px)" }}
                exit={{ opacity: 0, transform: "translateX(-8px)", filter: "blur(3px)" }}
                transition={{ duration: 0.25, ease: [0.22, 1, 0.36, 1] }}
              >
                {active ? (
                  <>
                    <header className="session-header">
                      <button className="back" onClick={() => setSelected("")} aria-label="Back to sessions">←</button>
                      <div><strong>{active.name}</strong><span>{active.scope} · {active.status}</span></div>
                      {active.plan && <span className="plan-chip">{active.plan}</span>}
                    </header>
                    {error && <div className="error-banner">{error}</div>}
                    <Feed items={state.feeds[selected] ?? []} />
                    {ask && <AskCard ask={ask} onAnswer={response => run(() => agentd.answer(selected, response))} />}
                    <Composer
                      busy={active.status === "streaming"}
                      queued={state.queues[selected]?.length ?? 0}
                      disabled={Boolean(ask)}
                      onSubmit={text => run(() => agentd.submit(selected, text))}
                      onQueue={text => run(() => agentd.enqueue(selected, text))}
                      onInterrupt={() => run(() => agentd.interrupt(selected))}
                    />
                  </>
                ) : (
                  <div className="desktop-empty"><strong>Pick an agent</strong><span>Its live conversation will open here.</span></div>
                )}
              </m.section>
            </AnimatePresence>
            {error && !active && <div className="error-banner global">{error}</div>}
          </main>
        )}
      </LazyMotion>
    </MotionConfig>
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
