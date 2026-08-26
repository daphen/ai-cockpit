import { AnimatePresence, animate, useMotionValue, useTransform } from "motion/react"
import * as m from "motion/react-m"
import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from "react"
import type { Session } from "./agentd"
import { Orb, orbTone } from "./Orb"
import { fadeSwap, iconSwap, panelSwap } from "./motion"

interface Props {
  sessionName: string
  currentTool?: string
  fleet: Session[]
  busy: boolean
  queue: string[]
  disabled?: boolean
  onSubmit: (text: string) => void
  onSteerQueued: (index: number) => void
  onInterrupt: () => void
  rosterExpanded: boolean
  onRosterExpandedChange: (expanded: boolean) => void
  rosterKey: string
  rosterHeader: ReactNode
  roster: ReactNode
}

export function Composer({ sessionName, currentTool, fleet, busy, queue, disabled, onSubmit, onSteerQueued, onInterrupt, rosterExpanded, onRosterExpandedChange, rosterKey, rosterHeader, roster }: Props) {
  const [text, setText] = useState("")
  const [confirmInterrupt, setConfirmInterrupt] = useState(false)
  const [compositorTray, setCompositorTray] = useState(() => matchMedia("(max-width: 720px)").matches)
  const textarea = useRef<HTMLTextAreaElement>(null)
  const dispatching = useRef(false)
  const allowLineBreak = useRef(false)
  const rosterContent = useRef<HTMLDivElement>(null)
  const [rosterHeight, setRosterHeight] = useState(320)
  const rosterProgress = useMotionValue(rosterExpanded ? 1 : 0)
  const rosterExtent = useMotionValue(rosterHeight)
  const rosterAnimation = useRef<ReturnType<typeof animate> | null>(null)
  const rosterExtentAnimation = useRef<ReturnType<typeof animate> | null>(null)
  const rosterShellHeight = useTransform(() => compositorTray ? rosterExtent.get() : rosterProgress.get() * rosterExtent.get())
  const trayOffset = useTransform(() => compositorTray ? (1 - rosterProgress.get()) * rosterExtent.get() : 0)
  const rosterClip = useTransform(() => `inset(0 0 ${(1 - rosterProgress.get()) * 100}% 0)`)
  const rosterOpacity = useTransform(rosterProgress, [0, 0.35, 1], [0, 0.35, 1])
  const fleetOpacity = useTransform(rosterProgress, [0, 0.6], [1, 0])
  const swipeStart = useRef<{ x: number; y: number; progress: number } | null>(null)
  const suppressRosterToggle = useRef(false)

  const toggleRoster = () => {
    if (suppressRosterToggle.current) {
      suppressRosterToggle.current = false
      return
    }
    onRosterExpandedChange(!rosterExpanded)
  }

  const beginRosterSwipe = (event: ReactPointerEvent<HTMLElement>) => {
    rosterAnimation.current?.stop()
    suppressRosterToggle.current = false
    swipeStart.current = { x: event.clientX, y: event.clientY, progress: rosterProgress.get() }
    event.currentTarget.setPointerCapture(event.pointerId)
  }

  const moveRosterSwipe = (event: ReactPointerEvent<HTMLElement>) => {
    const start = swipeStart.current
    if (!start) return
    const y = event.clientY - start.y
    rosterProgress.set(Math.max(0, Math.min(1, start.progress - y / Math.max(180, rosterHeight))))
  }

  const endRosterSwipe = (event: ReactPointerEvent<HTMLElement>) => {
    const start = swipeStart.current
    swipeStart.current = null
    if (!start) return
    const x = event.clientX - start.x
    const y = event.clientY - start.y
    suppressRosterToggle.current = Math.hypot(x, y) > 10
    const vertical = Math.abs(y) > Math.abs(x)
    const expanded = vertical && Math.abs(y) > 32 ? y < 0 : rosterProgress.get() >= 0.5
    onRosterExpandedChange(expanded)
    rosterAnimation.current?.stop()
    rosterAnimation.current = animate(rosterProgress, expanded ? 1 : 0, { type: "spring", bounce: 0, visualDuration: 0.28 })
  }

  const cancelRosterSwipe = () => {
    swipeStart.current = null
    suppressRosterToggle.current = false
    onRosterExpandedChange(rosterExpanded)
    rosterAnimation.current?.stop()
    rosterAnimation.current = animate(rosterProgress, rosterExpanded ? 1 : 0, { type: "spring", bounce: 0, visualDuration: 0.28 })
  }

  const closeInterrupt = (confirmed: boolean) => {
    setConfirmInterrupt(false)
    if (confirmed) onInterrupt()
    requestAnimationFrame(() => textarea.current?.focus({ preventScroll: true }))
  }

  const send = () => {
    const message = text.trim()
    if (!message || disabled || dispatching.current) return
    dispatching.current = true
    onSubmit(message)
    setText("")
    queueMicrotask(() => { dispatching.current = false })
    requestAnimationFrame(() => textarea.current?.focus({ preventScroll: true }))
  }

  useEffect(() => {
    const media = matchMedia("(max-width: 720px)")
    const update = () => setCompositorTray(media.matches)
    media.addEventListener("change", update)
    return () => media.removeEventListener("change", update)
  }, [])

  useLayoutEffect(() => {
    const node = rosterContent.current
    if (!node) return
    const measure = () => {
      const next = node.getBoundingClientRect().height
      setRosterHeight(next)
      rosterExtentAnimation.current?.stop()
      if (rosterProgress.get() > 0.01) {
        rosterExtentAnimation.current = animate(rosterExtent, next, { type: "spring", bounce: 0, visualDuration: 0.25 })
      } else {
        rosterExtent.set(next)
      }
    }
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(node)
    return () => {
      observer.disconnect()
      rosterExtentAnimation.current?.stop()
    }
  }, [rosterExtent, rosterProgress])

  useEffect(() => {
    rosterAnimation.current?.stop()
    const control = animate(rosterProgress, rosterExpanded ? 1 : 0, { type: "spring", bounce: 0, visualDuration: 0.28 })
    rosterAnimation.current = control
    return () => control.stop()
  }, [rosterExpanded, rosterProgress])

  useEffect(() => {
    const node = textarea.current
    if (!node) return
    const beforeInput = (event: InputEvent) => {
      if ((event.inputType === "insertLineBreak" || event.inputType === "insertParagraph") && !event.isComposing && !allowLineBreak.current) {
        event.preventDefault()
        send()
      }
    }
    node.addEventListener("beforeinput", beforeInput)
    return () => node.removeEventListener("beforeinput", beforeInput)
  })

  return (
    <form className="composer-sheet" onSubmit={event => { event.preventDefault(); send() }}>
      <m.div className="composer-surface" aria-hidden="true" style={{ y: trayOffset }} />
      <m.div className="roster-region" style={{ y: trayOffset }}>
        <button
          type="button"
          className="composer-drag-handle"
          aria-label={rosterExpanded ? "Collapse roster" : "Expand roster"}
          onClick={toggleRoster}
          onPointerDown={beginRosterSwipe}
          onPointerMove={moveRosterSwipe}
          onPointerUp={endRosterSwipe}
          onPointerCancel={cancelRosterSwipe}
        />
        <button
          type="button"
          className="composer-glance"
        aria-label={rosterExpanded ? "Close roster" : "Open roster"}
        onClick={toggleRoster}
        onPointerDown={beginRosterSwipe}
        onPointerMove={moveRosterSwipe}
        onPointerUp={endRosterSwipe}
        onPointerCancel={cancelRosterSwipe}
          style={{ touchAction: "pan-x" }}
        >
          <span className="composer-session"><strong>{sessionName.toUpperCase()}</strong></span>
          <m.span className="composer-dot-row" aria-label="Other session statuses" style={{ opacity: fleetOpacity }}>
            {fleet.slice(0, 8).map(session => (
              <span className="composer-dot-slot" key={`${session.scope}/${session.name}`}>
                {session.ask ? <span className="status-dot needs-input-dot" /> : session.status === "streaming" ? <Orb seedKey={session.name} size={16} tone={orbTone(session.currentTool)} /> : <span className={`status-dot ${session.status}`} />}
              </span>
            ))}
          </m.span>
        </button>
        <m.div className="inline-roster-shell" aria-hidden={!rosterExpanded} inert={!rosterExpanded} style={{ height: rosterShellHeight, opacity: rosterOpacity, clipPath: rosterClip }}>
        <div ref={rosterContent} className="inline-roster-content">
          {rosterHeader}
          <div className="inline-roster-stack">
            <AnimatePresence initial={false} mode="popLayout">
              <m.div
                className="inline-roster-panel"
                key={rosterKey}
                variants={iconSwap}
                initial="initial"
                animate="animate"
                exit="exit"
              >
                {roster}
              </m.div>
            </AnimatePresence>
          </div>
        </div>
        </m.div>
      </m.div>
      <AnimatePresence initial={false}>
        {!!queue.length && (
          <m.ol className="queued-messages" aria-label="Queued messages" variants={panelSwap} initial="initial" animate="animate" exit="exit">
            <AnimatePresence initial={false}>
              {queue.map((message, index) => (
                <m.li key={`${message}-${index}`} variants={iconSwap} initial="initial" animate="animate" exit="exit">
                  <span>{message}</span>
                  <button type="button" onPointerDown={event => event.preventDefault()} onClick={() => onSteerQueued(index)}>steer now</button>
                </m.li>
              ))}
            </AnimatePresence>
          </m.ol>
        )}
      </AnimatePresence>
      <div className="composer-pill">
        <span className="prompt-glyph">›</span>
        <textarea
          ref={textarea}
          rows={1}
          enterKeyHint="send"
          aria-label="Message"
          disabled={disabled}
          placeholder={disabled ? "answer the question above…" : busy ? `queue for ${sessionName}…` : `message ${sessionName}…`}
          value={text}
          onChange={event => setText(event.target.value)}
          onKeyDown={event => {
            if (event.key !== "Enter") return
            allowLineBreak.current = event.shiftKey
            if (!event.shiftKey) { event.preventDefault(); send() }
          }}
          onKeyUp={event => { if (event.key === "Enter") allowLineBreak.current = false }}
          onBlur={() => { allowLineBreak.current = false }}
        />
        <span className="orb-interrupt-slot">
          <AnimatePresence initial={false}>
            {busy && (
              <m.button
                type="button"
                className="orb-interrupt"
                aria-label="Interrupt active turn"
                variants={iconSwap}
                initial="initial"
                animate="animate"
                exit="exit"
                onPointerDown={event => event.preventDefault()}
                onClick={() => setConfirmInterrupt(true)}
              >
                <Orb seedKey={sessionName} size={44} tone={orbTone(currentTool)} />
              </m.button>
            )}
          </AnimatePresence>
        </span>
      </div>
      <AnimatePresence initial={false}>
        {confirmInterrupt && (
          <m.div className="interrupt-backdrop" role="alertdialog" aria-modal="true" aria-labelledby="interrupt-title" variants={fadeSwap} initial="initial" animate="animate" exit="exit" onPointerDown={event => { if (event.target === event.currentTarget) closeInterrupt(false) }}>
            <m.section className="interrupt-dialog" variants={iconSwap} initial="initial" animate="animate" exit="exit">
              <span>ACTIVE TURN</span>
              <h2 id="interrupt-title">Interrupt {sessionName}?</h2>
              <p>The agent will stop its current work immediately.</p>
              <div>
                <button type="button" onPointerDown={event => event.preventDefault()} onClick={() => closeInterrupt(false)}>keep working</button>
                <button type="button" className="confirm-interrupt" onPointerDown={event => event.preventDefault()} onClick={() => closeInterrupt(true)}>interrupt</button>
              </div>
            </m.section>
          </m.div>
        )}
      </AnimatePresence>
    </form>
  )
}
