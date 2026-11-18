// The ports of the Vite dev server and of the host: those of a dev build, or those of the end-to-end
// tests, which set SYNAPSE_DESKTOP_E2E in the environment of what they start. For programs that run
// under Node; the page reaches the host through the dev server and needs neither.

import { E2E_SERVER_PORT, E2E_WEB_PORT, SERVER_PORT, WEB_PORT } from './constants.ts'

export function ports(env: Record<string, string | undefined>): { web: number; server: number } {
  return env.SYNAPSE_DESKTOP_E2E === undefined
    ? { web: WEB_PORT, server: SERVER_PORT }
    : { web: E2E_WEB_PORT, server: E2E_SERVER_PORT }
}
