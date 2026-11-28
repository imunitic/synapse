import { describe, expect, it } from 'vitest'
import { E2E_SERVER_PORT, E2E_WEB_PORT, SERVER_PORT, WEB_PORT } from './constants.ts'
import { ports } from './ports.ts'

describe('the ports of the dev server and the host', () => {
  it('the server port can be given in the environment', () => {
    expect(ports({ SYNAPSE_DESKTOP_SERVER_PORT: '6123' })).toEqual({ web: WEB_PORT, server: 6123 })
    expect(ports({ SYNAPSE_DESKTOP_E2E: '1', SYNAPSE_DESKTOP_SERVER_PORT: '6123' })).toEqual({
      web: E2E_WEB_PORT,
      server: 6123,
    })
  })

  it('a server port that is not a port is ignored', () => {
    for (const value of ['', '0', '65536', '-1', '12.5', '80a', ' 80', 'port']) {
      expect(ports({ SYNAPSE_DESKTOP_SERVER_PORT: value })).toEqual({
        web: WEB_PORT,
        server: SERVER_PORT,
      })
      expect(ports({ SYNAPSE_DESKTOP_E2E: '1', SYNAPSE_DESKTOP_SERVER_PORT: value })).toEqual({
        web: E2E_WEB_PORT,
        server: E2E_SERVER_PORT,
      })
    }
  })
})
