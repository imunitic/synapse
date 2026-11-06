import { useConfig } from './config.tsx'

export function StatusBar() {
  const { state } = useConfig()
  const workDir =
    state.status === 'ready'
      ? (state.config.workDir ?? 'not set')
      : state.status === 'failed'
        ? 'unavailable'
        : '…'
  return (
    <footer className="statusbar">
      <span className="mono">work dir: {workDir}</span>
    </footer>
  )
}
