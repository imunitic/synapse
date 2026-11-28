// The served Node host is local-only until the remote authentication and execution
// boundaries are implemented. A requested remote mode must never silently fall back
// to the localhost token-based host and appear to have been enabled.
export function requireSupportedHostMode(env: Readonly<Record<string, string | undefined>>): void {
  const value = env.SYNAPSE_DESKTOP_HOST_MODE
  if (value === undefined || value === 'local') return
  if (value === 'remote') {
    throw new Error(
      'Synapse remote host mode is not implemented: authenticated users and isolated execution are required first',
    )
  }
  throw new Error(
    `Invalid SYNAPSE_DESKTOP_HOST_MODE: expected 'local' or 'remote', got ${JSON.stringify(value)}`,
  )
}
