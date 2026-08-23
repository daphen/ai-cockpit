/// <reference lib="webworker" />

const worker = self as unknown as ServiceWorkerGlobalScope
const cacheName = "cockpit-shell-v1"

worker.addEventListener("install", event => {
  event.waitUntil(caches.open(cacheName).then(cache => cache.addAll(["/", "/manifest.json"])))
})

worker.addEventListener("activate", event => {
  event.waitUntil(worker.clients.claim())
})

worker.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return
  event.respondWith(
    fetch(event.request)
      .then(response => {
        const copy = response.clone()
        void caches.open(cacheName).then(cache => cache.put(event.request, copy))
        return response
      })
      .catch(async () => (await caches.match(event.request)) ?? (await caches.match("/")) ?? Response.error()),
  )
})
