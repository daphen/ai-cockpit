export function LoadingIndicator({ label }: { label: string }) {
  return (
    <div className="loading-indicator" role="status">
      <img src="/icons/icon-192.png" alt="" />
      <div><strong>cockpit</strong><span>{label}</span></div>
      <span className="splash-progress" aria-hidden="true"><i /></span>
    </div>
  )
}
