// The ports of the Vite dev server and of the host: those of a dev build, or those of the end-to-end
// tests, which set SYNAPSE_DESKTOP_E2E in the environment of what they start. For programs that run
// under Node; the page reaches the host through the dev server and needs neither.
//
// SYNAPSE_DESKTOP_SERVER_PORT, when it holds a port, gives the host's port over either default, so a
// test can start a second host beside the shared end-to-end one.

import { E2E_SERVER_PORT, E2E_WEB_PORT, SERVER_PORT, WEB_PORT } from './constants.ts'

export function ports(env: Record<string, string | undefined>): { web: number; server: number } {
  const defaults =
    env.SYNAPSE_DESKTOP_E2E === undefined
      ? { web: WEB_PORT, server: SERVER_PORT }
      : { web: E2E_WEB_PORT, server: E2E_SERVER_PORT }
  const given = givenPort(env.SYNAPSE_DESKTOP_SERVER_PORT)
  return given === undefined ? defaults : { ...defaults, server: given }
}

// The port a variable holds: a whole number from 1 to 65535, or nothing.
function givenPort(value: string | undefined): number | undefined {
  if (value === undefined || !/^\d+$/.test(value)) return undefined
  const port = Number(value)
  return port >= 1 && port <= 65535 ? port : undefined
}
