import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import App from "./App"
import swUrl from "./sw.ts?worker&url"
import "./theme.css"

const viewport = window.visualViewport
let viewportFrame = 0
let fullViewportHeight = viewport?.height ?? window.innerHeight
const applyViewport = () => {
  viewportFrame = 0
  const height = viewport?.height ?? window.innerHeight
  const top = viewport?.offsetTop ?? 0
  if (!(document.activeElement instanceof HTMLInputElement || document.activeElement instanceof HTMLTextAreaElement)) {
    fullViewportHeight = Math.max(fullViewportHeight, height)
  }
  const keyboardOpen = fullViewportHeight - height > 80
  document.documentElement.style.setProperty("--app-height", `${height}px`)
  document.documentElement.style.setProperty("--app-top", `${top}px`)
  document.documentElement.style.setProperty("--app-safe-bottom", keyboardOpen ? "0px" : "env(safe-area-inset-bottom)")
  window.dispatchEvent(new CustomEvent("cockpit:viewport-change", { detail: { keyboardOpen } }))
}
const syncViewport = () => {
  cancelAnimationFrame(viewportFrame)
  viewportFrame = requestAnimationFrame(applyViewport)
}
applyViewport()
viewport?.addEventListener("resize", syncViewport)
viewport?.addEventListener("scroll", syncViewport)
window.addEventListener("resize", syncViewport)
window.addEventListener("orientationchange", () => {
  fullViewportHeight = viewport?.height ?? window.innerHeight
  syncViewport()
})

createRoot(document.getElementById("root")!).render(
  <StrictMode><App /></StrictMode>,
)

if ("serviceWorker" in navigator && window.isSecureContext) {
  let registration: ServiceWorkerRegistration | undefined
  let reloadOnChange = false
  let reloading = false
  const announce = () => window.dispatchEvent(new Event("cockpit:update-ready"))

  window.addEventListener("cockpit:apply-update", () => {
    if (!registration?.waiting) return
    reloadOnChange = true
    registration.waiting.postMessage({ type: "SKIP_WAITING" })
  })
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (!reloadOnChange || reloading) return
    reloading = true
    location.reload()
  })
  window.addEventListener("load", () => void navigator.serviceWorker.register(swUrl, { scope: "/", type: "module", updateViaCache: "none" }).then(next => {
    registration = next
    void navigator.serviceWorker.getRegistrations().then(registrations => {
      for (const item of registrations) if (new URL(item.scope).pathname === "/assets/") void item.unregister()
    })
    if (next.waiting) announce()
    next.addEventListener("updatefound", () => {
      const worker = next.installing
      worker?.addEventListener("statechange", () => {
        if (worker.state === "installed" && navigator.serviceWorker.controller) announce()
      })
    })
  }))
}
