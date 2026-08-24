import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import App from "./App"
import swUrl from "./sw.ts?worker&url"
import "./theme.css"

const viewport = window.visualViewport
const syncViewport = () => {
  document.documentElement.style.setProperty("--app-height", `${viewport?.height ?? window.innerHeight}px`)
  document.documentElement.style.setProperty("--app-top", `${viewport?.offsetTop ?? 0}px`)
}
syncViewport()
viewport?.addEventListener("resize", syncViewport)
viewport?.addEventListener("scroll", syncViewport)
window.addEventListener("resize", syncViewport)

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
