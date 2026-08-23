import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import App from "./App"
import swUrl from "./sw.ts?worker&url"
import "./theme.css"

createRoot(document.getElementById("root")!).render(
  <StrictMode><App /></StrictMode>,
)

if ("serviceWorker" in navigator) window.addEventListener("load", () => navigator.serviceWorker.register(swUrl, { type: "module" }))
