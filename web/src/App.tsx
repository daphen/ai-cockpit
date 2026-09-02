import { useEffect, useMemo, useState, useSyncExternalStore } from "react"
import { AnimatePresence, domAnimation, LazyMotion, MotionConfig } from "motion/react"
import * as m from "motion/react-m"
import { agentd, sessionKey, UnauthorizedError } from "./agentd"
import { AskCard } from "./AskCard"
import { Composer } from "./Composer"
import { Feed } from "./Feed"
import { LoadingIndicator } from "./LoadingIndicator"
import { Roster } from "./Roster"
import { fadeSwap, pageSwap, panelSwap, textSwap } from "./motion"

const tokenKey = "cockpit.bridgeToken"
const lastSessionKey = "cockpit.lastSession"
type CockpitGroup = "work" | "private"
const groupScopes: Record<CockpitGroup, Set<string>> = {
  work: new Set(["lovable", "work"]),
  private: new Set(["personal", "chat"]),
}

function groupForSession(key: string): CockpitGroup {
  const sessionScope = key.slice(0, key.indexOf("/"))
  return sessionScope === "personal" || sessionScope === "chat" ? "private" : "work"
}

export default function App() {
  const state = useSyncExternalStore(agentd.subscribe, agentd.getSnapshot)
  const rememberedSession = localStorage.getItem(lastSessionKey) ?? ""
  const rememberedGroup = groupForSession(rememberedSession)
  const [selected, setSelected] = useState(rememberedSession)
  const [restoringSession, setRestoringSession] = useState(Boolean(rememberedSession))
  const [group, setGroup] = useState<CockpitGroup>(rememberedGroup)
  const [scope, setScope] = useState(rememberedSession.startsWith("chat/") ? "chat" : rememberedGroup === "private" ? "personal" : "all")
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
    return () => {
      document.removeEventListener("visibilitychange", resume)
      window.removeEventListener("pageshow", resume)
      window.removeEventListener("online", resume)
    }
  }, [checkingToken, needsToken])
  const groupSessions = useMemo(() => state.sessions.filter(session => groupScopes[group].has(session.scope)), [group, state.sessions])
  // The armed watchdog goal is the authoritative handover signal. Keep the last holder
  // only as a fallback while no orchestrator has a goal, so clearing a completed goal
  // does not move the visible conductor.
  const [pinnedOrchScope, setPinnedOrchScope] = useState(() => {
    try {
      return localStorage.getItem("cockpit.orchScope") ?? ""
    } catch {
      return ""
    }
  })
  const orchScope = useMemo(() => {
    const orchestrators = state.sessions.filter(session =>
      (session.profile ?? "").includes("orchestrator") &&
      (session.scope === "lovable" || session.scope === "work"))
    if (state.orchestratorScope && orchestrators.some(session => session.scope === state.orchestratorScope)) {
      return state.orchestratorScope
    }
    const armed = orchestrators.find(session => session.goal)
    if (armed) return armed.scope
    if (pinnedOrchScope && orchestrators.some(session => session.scope === pinnedOrchScope)) {
      return pinnedOrchScope
    }
    return orchestrators[0]?.scope ?? ""
  }, [state.sessions, state.orchestratorScope, pinnedOrchScope])
  useEffect(() => {
    if (!orchScope || orchScope === pinnedOrchScope) return
    setPinnedOrchScope(orchScope)
    try {
      localStorage.setItem("cockpit.orchScope", orchScope)
    } catch {
      /* private window / blocked storage: pinning is a convenience, not a requirement */
    }
  }, [orchScope, pinnedOrchScope])

  const visibleSessions = useMemo(() => {
    const inScope = scope === "all" ? groupSessions : groupSessions.filter(session => session.scope === scope)
    // Hide the stood-down orchestrator on the other host — one conductor, one row.
    return inScope.filter(session => !(
      (session.profile ?? "").includes("orchestrator") && orchScope && session.scope !== orchScope
    ))
  }, [groupSessions, scope, orchScope])
  const selectedAvailable = state.sessions.some(session => sessionKey(session.scope, session.name) === selected)
  useEffect(() => {
    if (restoringSession && selectedAvailable) setRestoringSession(false)
  }, [restoringSession, selectedAvailable])
  useEffect(() => {
    if (!restoringSession || checkingToken || !state.sessions.length) return
    const timer = window.setTimeout(() => setRestoringSession(false), 2500)
    return () => window.clearTimeout(timer)
  }, [checkingToken, restoringSession, state.sessions.length])
  useEffect(() => {
    if (restoringSession || selectedAvailable) return
    const first = visibleSessions[0]
    setSelected(first ? sessionKey(first.scope, first.name) : "")
  }, [restoringSession, selectedAvailable, visibleSessions])
  useEffect(() => {
    if (!selectedAvailable) return
    localStorage.setItem(lastSessionKey, selected)
    agentd.select(selected)
  }, [selected, selectedAvailable])
  const selectSession = (key: string) => {
    setRestoringSession(false)
    setSelected(key)
  }
  useEffect(() => { if (scope === "chat") agentd.labelChats(visibleSessions) }, [scope, visibleSessions])

  const active = state.sessions.find(session => sessionKey(session.scope, session.name) === selected)
  const activeFamily = useMemo(() => {
    if (!active) return []
    const family = new Set([active.name])
    let changed = true
    while (changed) {
      changed = false
      for (const session of state.sessions) {
        if (session.scope !== active.scope || !session.parent || !family.has(session.parent) || family.has(session.name)) continue
        family.add(session.name)
        changed = true
      }
    }
    return state.sessions.filter(session => session.scope === active.scope && session.name !== active.name && family.has(session.name))
  }, [active, state.sessions])
  const activeFamilyKeys = new Set(activeFamily.map(session => sessionKey(session.scope, session.name)))
  const remainingRoster = visibleSessions.filter(session => sessionKey(session.scope, session.name) !== selected && !activeFamilyKeys.has(sessionKey(session.scope, session.name)))
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
        <AnimatePresence initial={false} mode="wait">
        {checkingToken || (!needsToken && loadingCockpit) ? (
          <Splash key="splash" label={checkingToken ? "connecting bridges" : "loading rosters"} />
        ) : needsToken ? (
          <TokenLogin key="login" checking={false} error={error} onSubmit={saveToken} />
        ) : (
          <m.main className={`app ${active ? "session-open" : ""}`} key="app" variants={pageSwap} initial="initial" animate="animate" exit="exit">
            <aside className="roster-pane">
              <header className="app-header"><div><span>cockpit</span><strong>{group}</strong></div><small>{groupSessions.length} agents</small></header>
              <nav className="group-tabs" aria-label="Cockpit group">
                {(["work", "private"] as CockpitGroup[]).map(item => (
                  <button className={group === item ? "active" : ""} key={item} onClick={() => chooseGroup(item)}>{item}</button>
                ))}
              </nav>
              <nav className="scope-tabs" aria-label={`${group} scope filter`} hidden>
                {["all", ...scopes].map(item => <button className={scope === item ? "active" : ""} key={item} onClick={() => chooseScope(item)}>{item}</button>)}
              </nav>
              <Roster sessions={visibleSessions} selected={selected} onSelect={selectSession} />
            </aside>

            <div className="session-stage">
            <AnimatePresence initial={false}>
              <m.section
                className="session-pane"
                key={selected || "empty"}
                variants={pageSwap}
                initial="initial"
                animate="animate"
                exit="exit"
              >
                {active ? (
                  <>
                    <header className="session-header">
                      <button className="back" onClick={() => setRosterExpanded(true)} aria-label="Open roster">←</button>
                      <div><strong>{active.displayName ?? active.name}</strong><span>{active.scope} · {active.status}</span></div>
                      <AnimatePresence initial={false}>
                        {active.plan && <m.span className="plan-chip" key={active.plan} variants={textSwap} initial="initial" animate="animate" exit="exit">{active.plan}</m.span>}
                      </AnimatePresence>
                    </header>
                    <AnimatePresence initial={false}>
                      {error && <m.div className="error-banner" key={error} variants={textSwap} initial="initial" animate="animate" exit="exit">{error}</m.div>}
                    </AnimatePresence>
                    <Feed items={state.feeds[selected]} pinToEnd={Boolean(ask)} />
                    <AnimatePresence initial={false}>
                      {ask && <AskCard key={`${ask.title}-${ask.method}`} ask={ask} onAnswer={response => run(() => agentd.answer(selected, response))} />}
                    </AnimatePresence>
                    <Composer
                      sessionName={active.displayName ?? active.name}
                      currentTool={active.currentTool}
                      fleet={visibleSessions.filter(session => session.scope !== "chat" && sessionKey(session.scope, session.name) !== selected)}
                      busy={active.status === "streaming"}
                      queue={state.queues[selected] ?? []}
                      disabled={Boolean(ask)}
                      onSubmit={text => run(() => agentd.submit(selected, text))}
                      onUploadImage={file => agentd.uploadImage(selected, file)}
                      onSteerQueued={index => run(() => agentd.steerQueued(selected, index))}
                      onInterrupt={() => run(() => agentd.interrupt(selected))}
                      rosterExpanded={rosterExpanded}
                      onRosterExpandedChange={setRosterExpanded}
                      rosterKey={`${group}/${scope}`}
                      rosterFeatured={activeFamily.length ? (
                        <div className="featured-nested-roster">
                          <Roster sessions={activeFamily} selected={selected} onSelect={key => { selectSession(key); setRosterExpanded(false) }} />
                        </div>
                      ) : null}
                      rosterHeader={(
                        <nav className="group-tabs" aria-label="Cockpit group">
                          {(["work", "private"] as CockpitGroup[]).map(item => <button type="button" className={group === item ? "active" : ""} key={item} onClick={() => chooseGroup(item)}>{item}</button>)}
                        </nav>
                      )}
                      roster={(
                        <>
                          <nav className="scope-tabs" aria-label={`${group} scope filter`} hidden>
                            {["all", ...scopes].map(item => <button type="button" className={scope === item ? "active" : ""} key={item} onClick={() => chooseScope(item)}>{item}</button>)}
                          </nav>
                          <Roster sessions={remainingRoster} selected={selected} onSelect={key => { selectSession(key); setRosterExpanded(false) }} />
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
            <AnimatePresence initial={false}>
              {error && !active && <m.div className="error-banner global" key={error} variants={panelSwap} initial="initial" animate="animate" exit="exit">{error}</m.div>}
            </AnimatePresence>
          </m.main>
        )}
        </AnimatePresence>
        <AnimatePresence initial={false}>
          {updateReady && (
            <m.div className="update-toast" role="status" variants={panelSwap} initial="initial" animate="animate" exit="exit">
              <span>new cockpit ready</span>
              <button onClick={() => window.dispatchEvent(new Event("cockpit:apply-update"))}>update & reload</button>
            </m.div>
          )}
        </AnimatePresence>
      </LazyMotion>
    </MotionConfig>
  )
}

function Splash({ label }: { label: string }) {
  return (
    <m.main className="boot-splash" variants={fadeSwap} initial="initial" animate="animate" exit="exit">
      <LoadingIndicator label={label} />
    </m.main>
  )
}

function TokenLogin({ checking, error, onSubmit }: { checking: boolean; error: string; onSubmit: (token: string) => void }) {
  const [value, setValue] = useState("")
  const valid = /^[0-9a-f]{64}$/.test(value)
  return (
    <m.main className="token-shell" variants={pageSwap} initial="initial" animate="animate" exit="exit">
      <m.form
        className="token-card"
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
            <AnimatePresence initial={false}>
              {error && <m.div className="token-error" key={error} variants={textSwap} initial="initial" animate="animate" exit="exit">{error}</m.div>}
            </AnimatePresence>
            <button className="primary" disabled={!valid}>Connect</button>
          </>
        )}
      </m.form>
    </m.main>
  )
}
