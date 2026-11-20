// Operator-provisioned password verifier for the private two-user gateway.
// No passwords or account hashes are bundled with Synapse. The gateway entry
// point must load records from a protected external configuration at startup.
import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto'
const COST = 16384
const BLOCK_SIZE = 8
const PARALLEL = 1
const KEY_BYTES = 32
const MAX_MEMORY = 64 * 1024 * 1024
const HASH_PATTERN = /^scrypt\$16384\$8\$1\$([0-9a-f]{32})\$([0-9a-f]{64})$/

export const VERIFIER_BUSY = Symbol('verifier_busy')

export interface PasswordAccount {
  readonly username: string
  readonly userId: string
  readonly passwordHash: string
}

function validIdentifier(value: string): boolean {
  return /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$/.test(value)
}

async function derive(password: string, salt: Buffer): Promise<Buffer> {
  return new Promise<Buffer>((resolve, reject) => {
    scryptCallback(
      password,
      salt,
      KEY_BYTES,
      { N: COST, r: BLOCK_SIZE, p: PARALLEL, maxmem: MAX_MEMORY },
      (error, key) => {
        if (error) reject(error)
        else resolve(key)
      },
    )
  })
}

/**
 * Intended for a one-time, operator-controlled provisioning tool. Never run
 * with real passwords in CI, command-line arguments, logs or source files.
 */
export async function hashGatewayPassword(password: string): Promise<string> {
  password = password.normalize('NFC')
  if (password.length < 12 || Buffer.byteLength(password, 'utf8') > 1024) {
    throw new Error('password must be between 12 and 1024 characters')
  }
  const salt = randomBytes(16)
  const key = await derive(password, salt)
  return `scrypt$${COST}$${BLOCK_SIZE}$${PARALLEL}$${salt.toString('hex')}$${key.toString('hex')}`
}

export function createPasswordVerifier(accounts: readonly PasswordAccount[]) {
  if (accounts.length < 1 || accounts.length > 16) throw new Error('invalid account count')
  const known = new Map<string, { userId: string; salt: Buffer; digest: Buffer }>()
  const userIds = new Set<string>()
  for (const account of accounts) {
    const parsed = HASH_PATTERN.exec(account.passwordHash)
    if (
      !validIdentifier(account.username) ||
      !validIdentifier(account.userId) ||
      !parsed?.[1] ||
      !parsed[2] ||
      known.has(account.username) ||
      userIds.has(account.userId)
    ) {
      throw new Error('invalid or duplicate gateway account')
    }
    const salt = Buffer.from(parsed[1], 'hex')
    const digest = Buffer.from(parsed[2], 'hex')
    known.set(account.username, { userId: account.userId, salt, digest })
    userIds.add(account.userId)
  }
  // Unknown usernames still perform an expensive hash comparison to avoid
  // trivially exposing configured account names through response latency.
  const fallback = { userId: '', salt: randomBytes(16), digest: randomBytes(KEY_BYTES) }
  let pending = 0
  const MAX_CONCURRENT_HASHES = 2

  return async (
    username: string,
    password: string,
  ): Promise<string | null | typeof VERIFIER_BUSY> => {
    password = password.normalize('NFC')
    if (password.length < 1 || Buffer.byteLength(password, 'utf8') > 1024) return null
    // Bound the amount of memory-intensive scrypt work scheduled at once.
    // Refusing excess requests is safer than allowing an authentication flood
    // to exhaust the gateway's constrained memory budget.
    if (pending >= MAX_CONCURRENT_HASHES) return VERIFIER_BUSY
    pending += 1
    try {
      const entry = known.get(username) ?? fallback
      const candidate = await derive(password, entry.salt)
      const matched = timingSafeEqual(candidate, entry.digest)
      return matched && known.has(username) ? entry.userId : null
    } finally {
      pending -= 1
    }
  }
}
