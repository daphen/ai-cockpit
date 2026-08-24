/// <reference lib="webworker" />

declare const __COCKPIT_BUILD__: string

const worker = self as unknown as ServiceWorkerGlobalScope
const cacheName = `cockpit-shell-${__COCKPIT_BUILD__}`

worker.addEventListener("install", event => {
  event.waitUntil(caches.open(cacheName).then(cache => cache.addAll(["/", "/manifest.json"])))
})

worker.addEventListener("message", event => {
  if (event.data?.type === "SKIP_WAITING") void worker.skipWaiting()
})

worker.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key.startsWith("cockpit-shell-") && key !== cacheName).map(key => caches.delete(key))))
      .then(() => worker.clients.claim()),
  )
})

worker.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return
  event.respondWith(
    fetch(event.request)
      .then(response => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        const copy = response.clone()
        void caches.open(cacheName).then(cache => cache.put(event.request, copy))
        return response
      })
      .catch(async () => (await caches.match(event.request)) ?? (await caches.match("/")) ?? Response.error()),
  )
})
