export interface BridgeHost {
  id: string
  baseUrl: string
  homeScopes: string[]
}

const peers: BridgeHost[] = [
  { id: "proart", baseUrl: "https://proart.tail78a7a5.ts.net:8443", homeScopes: ["personal", "chat", "lovable"] },
  { id: "work-vm", baseUrl: "https://cockpit-work-vm.tail78a7a5.ts.net", homeScopes: ["work"] },
]

export function bridgeHosts(): BridgeHost[] {
  const origin = location.origin.replace(/\/$/, "")
  const knownOrigin = peers.find(host => host.baseUrl === origin)
  const own = knownOrigin ?? { id: "current", baseUrl: origin, homeScopes: [] }
  return [own, ...peers.filter(host => host.id !== own.id)]
}

export function hostRank(host: BridgeHost, scope: string) {
  if (host.homeScopes.includes(scope)) return 0
  if (host.id === "current") return 1
  return 2
}
