import { animate, useMotionValue } from "motion/react"
import * as m from "motion/react-m"
import { useRef, useState } from "react"

interface Props {
  busy: boolean
  queued: number
  disabled?: boolean
  onSubmit: (text: string) => void
  onQueue: (text: string) => void
  onInterrupt: () => void
}

interface AnimationControl {
  stop: () => void
  then?: (onfulfilled: () => void) => unknown
}

export function Composer({ busy, queued, disabled, onSubmit, onQueue, onInterrupt }: Props) {
  const [text, setText] = useState("")
  const progress = useMotionValue(0)
  const control = useRef<AnimationControl | null>(null)
  const held = useRef(false)
  const queuedByHold = useRef(false)

  const send = () => {
    const message = text.trim()
    if (!message || disabled) return
    onSubmit(message)
    setText("")
  }
  const startHold = () => {
    held.current = true
    queuedByHold.current = false
    control.current?.stop()
    if (!busy) return
    control.current = animate(progress, 1, { duration: 0.65, ease: "linear" })
    control.current.then?.(() => {
      const message = text.trim()
      if (!held.current || !message) return
      onQueue(message)
      setText("")
      queuedByHold.current = true
    })
  }
  const endHold = () => {
    held.current = false
    control.current?.stop()
    control.current = animate(progress, 0, { duration: 0.15, ease: "easeOut" })
    if (!queuedByHold.current) send()
  }
  const cancelHold = () => {
    held.current = false
    control.current?.stop()
    control.current = animate(progress, 0, { duration: 0.15, ease: "easeOut" })
  }

  return (
    <form className="composer" onSubmit={event => { event.preventDefault(); send() }}>
      <textarea
        aria-label="Message"
        disabled={disabled}
        placeholder={disabled ? "Answer the question above" : busy ? "Steer this turn…" : "Message this agent…"}
        value={text}
        onChange={event => setText(event.target.value)}
        onKeyDown={event => {
          if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); send() }
        }}
      />
      <div className="composer-actions">
        {busy && <button type="button" className="interrupt" onClick={onInterrupt}>Interrupt</button>}
        <span>{queued ? `${queued} queued` : busy ? "hold send to queue" : ""}</span>
        <m.button
          type="button"
          className="primary send"
          disabled={disabled || !text.trim()}
          onPointerDown={startHold}
          onPointerUp={endHold}
          onPointerCancel={cancelHold}
          whileTap={{ transform: "scale(0.96)" }}
          style={{ willChange: "transform" }}
        >
          <m.span className="hold-progress" style={{ scaleX: progress }} />
          <span className="send-label">{busy ? "Steer" : "Send"}</span>
        </m.button>
      </div>
    </form>
  )
}
