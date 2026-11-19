import { describe, expect, it } from 'vitest'
import { requireSupportedHostMode } from './host-mode.ts'

describe('served host mode', () => {
  it('preserves the current local host when the mode is unspecified', () => {
    expect(() => requireSupportedHostMode({})).not.toThrow()
  })

  it('accepts an explicit local mode', () => {
    expect(() => requireSupportedHostMode({ SYNAPSE_DESKTOP_HOST_MODE: 'local' })).not.toThrow()
  })

  it('refuses remote mode before remote authentication and isolation exist', () => {
    expect(() => requireSupportedHostMode({ SYNAPSE_DESKTOP_HOST_MODE: 'remote' })).toThrow(
      /authenticated users and isolated execution/,
    )
  })

  it.each(['', 'LOCAL', 'remote ', '0', 'public'])('refuses an unknown mode %j', (mode) => {
    expect(() => requireSupportedHostMode({ SYNAPSE_DESKTOP_HOST_MODE: mode })).toThrow(
      /Invalid SYNAPSE_DESKTOP_HOST_MODE/,
    )
  })
})
