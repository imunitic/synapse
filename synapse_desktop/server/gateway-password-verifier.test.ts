import { describe, expect, it } from 'vitest'
import {
  createPasswordVerifier,
  hashGatewayPassword,
  VERIFIER_BUSY,
  type PasswordAccount,
} from './gateway-password-verifier.ts'

describe('operator-provisioned gateway credentials', () => {
  it('verifies scrypt password hashes without trusting the submitted identity', async () => {
    const passwordHash = await hashGatewayPassword('fixture-long-password')
    const accounts: PasswordAccount[] = [{ username: 'alice', userId: 'user-alice', passwordHash }]
    const verify = createPasswordVerifier(accounts)
    expect(await verify('alice', 'fixture-long-password')).toBe('user-alice')
    expect(await verify('alice', 'wrong-password')).toBeNull()
    expect(await verify('unknown', 'fixture-long-password')).toBeNull()
    expect(await verify('alice', '')).toBeNull()
  })

  it('normalizes Unicode password input consistently between provisioning and login', async () => {
    const composed = 'pássword-very-long'
    const decomposed = composed.normalize('NFD')
    const hash = await hashGatewayPassword(composed)
    const verify = createPasswordVerifier([
      { username: 'alice', userId: 'alice', passwordHash: hash },
    ])
    expect(await verify('alice', decomposed)).toBe('alice')
    const other = await hashGatewayPassword(decomposed)
    const verifyOther = createPasswordVerifier([
      { username: 'alice', userId: 'alice', passwordHash: other },
    ])
    expect(await verifyOther('alice', composed)).toBe('alice')
  })

  it('does not confuse the reserved busy result with a legitimate user ID', async () => {
    const hash = await hashGatewayPassword('fixture-long-password')
    const verify = createPasswordVerifier([
      { username: 'alice', userId: 'busy', passwordHash: hash },
    ])
    expect(await verify('alice', 'fixture-long-password')).toBe('busy')
  })

  it('uses random salts even when passwords match', async () => {
    const first = await hashGatewayPassword('fixture-long-password')
    const second = await hashGatewayPassword('fixture-long-password')
    expect(first).toMatch(/^scrypt\$16384\$8\$1\$[0-9a-f]{32}\$[0-9a-f]{64}$/)
    expect(first).not.toBe(second)
    const verify = createPasswordVerifier([
      { username: 'alice', userId: 'user-alice', passwordHash: first },
      { username: 'bob', userId: 'user-bob', passwordHash: second },
    ])
    expect(await verify('bob', 'fixture-long-password')).toBe('user-bob')
  })

  it('limits concurrent expensive password checks and recovers after they settle', async () => {
    const passwordHash = await hashGatewayPassword('fixture-long-password')
    const verify = createPasswordVerifier([
      { username: 'alice', userId: 'user-alice', passwordHash },
    ])
    const checks = [
      verify('alice', 'fixture-long-password'),
      verify('alice', 'fixture-long-password'),
      verify('alice', 'fixture-long-password'),
    ]
    expect(await checks[2]).toBe(VERIFIER_BUSY)
    expect(await Promise.all(checks.slice(0, 2))).toEqual(['user-alice', 'user-alice'])
    expect(await verify('alice', 'fixture-long-password')).toBe('user-alice')
  })

  it('rejects duplicate identities and unsupported or malformed hash parameters', async () => {
    const passwordHash = await hashGatewayPassword('fixture-long-password')
    const first = { username: 'alice', userId: 'user-alice', passwordHash }
    expect(() => createPasswordVerifier([])).toThrow()
    expect(() => createPasswordVerifier([first, first])).toThrow()
    expect(() =>
      createPasswordVerifier([first, { username: 'bob', userId: 'user-alice', passwordHash }]),
    ).toThrow()
    expect(() =>
      createPasswordVerifier([
        { ...first, passwordHash: passwordHash.replace('16384', '1048576') },
      ]),
    ).toThrow()
    expect(() => createPasswordVerifier([{ ...first, username: '../alice' }])).toThrow()
    await expect(hashGatewayPassword('short')).rejects.toThrow()
  })
})
