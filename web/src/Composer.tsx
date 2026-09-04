import { AnimatePresence, animate, useMotionValue, useTransform } from "motion/react"
import * as m from "motion/react-m"
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from "react"
import type { Session } from "./agentd"
import { Orb, orbTone } from "./Orb"
import { fadeSwap, iconSwap, panelSwap } from "./motion"

interface Props {
  sessionName: string
  activeKey: string
  currentTool?: string
  fleet: Session[]
  busy: boolean
  queue: string[]
  disabled?: boolean
  onSubmit: (text: string) => void
  onUploadImage: (file: File) => Promise<string>
  onSteerQueued: (index: number) => void
  onInterrupt: () => void
  rosterExpanded: boolean
  onRosterExpandedChange: (expanded: boolean) => void
  rosterKey: string
  rosterFeatured: ReactNode
  rosterHeader: ReactNode
  roster: ReactNode
}

interface SessionRoot {
  key: string
  name: string
  scope: string
  status: Session["status"]
  ask: boolean
  tones: Array<ReturnType<typeof orbTone>>
  memberKeys: string[]
}

function sessionRoots(sessions: Session[]) {
  const byKey = new Map(sessions.map(session => [`${session.scope}/${session.name}`, session]))
  const groups = new Map<string, { root: Session; members: Session[] }>()
  for (const session of sessions) {
    let root = session
    const seen = new Set<string>()
    while (root.parent) {
      const parentKey = `${root.scope}/${root.parent}`
      if (seen.has(parentKey)) break
      seen.add(parentKey)
      const parent = byKey.get(parentKey)
      if (!parent) break
      root = parent
    }
    const key = `${root.scope}/${root.name}`
    const group = groups.get(key)
    if (group) group.members.push(session)
    else groups.set(key, { root, members: [session] })
  }
  return [...groups.entries()].map<SessionRoot>(([key, { root, members }]) => {
    const working = members.filter(session => session.status === "streaming")
    const status = working.length ? "streaming"
      : members.some(session => session.status === "error") ? "error"
      : root.status
    return {
      key,
      name: root.name,
      scope: root.scope,
      status,
      ask: members.some(session => Boolean(session.ask)),
      tones: working.map(session => orbTone(session.currentTool)),
      memberKeys: members.map(session => `${session.scope}/${session.name}`),
    }
  })
}

interface PendingImage {
  id: string
  name: string
  preview: string
  path?: string
  error?: string
}

export function Composer({ sessionName, activeKey, currentTool, fleet, busy, queue, disabled, onSubmit, onUploadImage, onSteerQueued, onInterrupt, rosterExpanded, onRosterExpandedChange, rosterKey, rosterFeatured, rosterHeader, roster }: Props) {
  const [text, setText] = useState("")
  const [images, setImages] = useState<PendingImage[]>([])
  const [confirmInterrupt, setConfirmInterrupt] = useState(false)
  const [compositorTray, setCompositorTray] = useState(() => matchMedia("(max-width: 720px)").matches)
  const textarea = useRef<HTMLTextAreaElement>(null)
  const imageInput = useRef<HTMLInputElement>(null)
  const imageUrls = useRef(new Set<string>())
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
  const collapsedRoots = useMemo(() => sessionRoots(fleet)
    .filter(root => root.scope !== "chat" && (!busy || !root.memberKeys.includes(activeKey)))
    .slice(0, 8), [activeKey, busy, fleet])

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

  const removeImage = (id: string) => {
    setImages(current => {
      const image = current.find(item => item.id === id)
      if (image) {
        URL.revokeObjectURL(image.preview)
        imageUrls.current.delete(image.preview)
      }
      return current.filter(item => item.id !== id)
    })
  }

  const addImages = (files: FileList | null) => {
    const available = Math.max(0, 4 - images.length)
    for (const file of Array.from(files ?? []).slice(0, available)) {
      const id = `${Date.now()}-${Math.random()}`
      if (!/^image\/(jpeg|png|webp|gif)$/.test(file.type) || file.size > 12 * 1024 * 1024) {
        setImages(current => [...current, { id, name: file.name, preview: "", error: file.size > 12 * 1024 * 1024 ? "over 12 MB" : "unsupported format" }])
        continue
      }
      const preview = URL.createObjectURL(file)
      imageUrls.current.add(preview)
      setImages(current => [...current, { id, name: file.name, preview }])
      void onUploadImage(file).then(path => {
        setImages(current => current.map(item => item.id === id ? { ...item, path } : item))
      }).catch(cause => {
        setImages(current => current.map(item => item.id === id ? { ...item, error: cause instanceof Error ? cause.message : "upload failed" } : item))
      })
    }
    if (imageInput.current) imageInput.current.value = ""
  }

  const send = () => {
    if (images.some(image => !image.path && !image.error)) return
    const refs = images.filter(image => image.path).map((image, index) => `[image ${index + 1}] @${image.path}`)
    const message = [text.trim(), ...refs].filter(Boolean).join("\n\n")
    if (!message || disabled || dispatching.current) return
    dispatching.current = true
    onSubmit(message)
    window.dispatchEvent(new Event("cockpit:message-sent"))
    setText("")
    for (const image of images) if (image.preview) URL.revokeObjectURL(image.preview)
    imageUrls.current.clear()
    setImages([])
    queueMicrotask(() => { dispatching.current = false })
    requestAnimationFrame(() => textarea.current?.focus({ preventScroll: true }))
  }

  useEffect(() => () => {
    for (const url of imageUrls.current) URL.revokeObjectURL(url)
    imageUrls.current.clear()
  }, [])

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
          <m.span className="composer-dot-row" aria-label="Session statuses" style={{ opacity: fleetOpacity }}>
            {collapsedRoots.map(root => (
              <span className="composer-dot-slot" key={root.key}>
                {root.ask ? <span className="status-dot needs-input-dot" /> : root.status === "streaming" ? <Orb seedKey={root.key} size={16} tones={root.tones} /> : <span className={`status-dot ${root.status}`} />}
              </span>
            ))}
          </m.span>
        </button>
        <m.div className="inline-roster-shell" aria-hidden={!rosterExpanded} inert={!rosterExpanded} style={{ height: rosterShellHeight, opacity: rosterOpacity, clipPath: rosterClip }}>
        <div ref={rosterContent} className={`inline-roster-content ${rosterFeatured ? "has-featured" : ""}`}>
          {rosterFeatured}
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
          {rosterHeader}
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
      {!!images.length && (
        <div className="attachment-tray" aria-label="Image attachments">
          {images.map(image => (
            <div className={`attachment-chip ${image.error ? "error" : image.path ? "ready" : "uploading"}`} key={image.id}>
              {image.preview ? <img src={image.preview} alt="" /> : <span className="attachment-placeholder" />}
              <span>{image.error ? `${image.name} · ${image.error}` : image.path ? image.name : `${image.name} · uploading`}</span>
              <button type="button" aria-label={`Remove ${image.name}`} onClick={() => removeImage(image.id)}>×</button>
            </div>
          ))}
        </div>
      )}
      <div className="composer-pill">
        <input ref={imageInput} className="image-input" type="file" accept="image/jpeg,image/png,image/webp,image/gif" multiple onChange={event => addImages(event.target.files)} />
        <button type="button" className="attach-button" aria-label="Attach images" disabled={disabled || images.length >= 4} onPointerDown={event => event.preventDefault()} onClick={() => imageInput.current?.click()}>
          <svg viewBox="0 0 18 18" aria-hidden="true"><path d="M13.75,4.25c-.414,0-.75,.336-.75,.75v6.75c0,2.068-1.682,3.75-3.75,3.75s-3.75-1.682-3.75-3.75V4.75c0-1.241,1.009-2.25,2.25-2.25s2.25,1.009,2.25,2.25v7c0,.414-.336,.75-.75,.75s-.75-.336-.75-.75V5c0-.414-.336-.75-.75-.75s-.75,.336-.75,.75v6.75c0,1.241,1.009,2.25,2.25,2.25s2.25-1.009,2.25-2.25V4.75c0-2.068-1.682-3.75-3.75-3.75s-3.75,1.682-3.75,3.75v7c0,2.895,2.355,5.25,5.25,5.25s5.25-2.355,5.25-5.25V5c0-.414-.336-.75-.75-.75Z" /></svg>
        </button>
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
