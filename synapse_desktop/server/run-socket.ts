// Asking a running pipeline about itself over its socket (a named pipe on
// Windows): one JSON request ended by a line feed, one JSON answer.

import { lstatSync, realpathSync } from 'node:fs'
import { createConnection } from 'node:net'
import { dirname, join } from 'node:path'
import type { RunAnswer } from '../shared/transport.ts'

const TIMEOUT_MS = 3000
const MAX_ANSWER_BYTES = 2 * 1024 * 1024

// The longest path a run's socket is given, with room to spare under the
// limit of a Unix socket's path (sun_path: 104 bytes on macOS, 108 on Linux).
export const MAX_SOCKET_PATH = 100

const FNV_OFFSET = 0xcbf29ce484222325n
const FNV_PRIME = 0x100000001b3n
const U64 = (1n << 64n) - 1n

// The 64-bit FNV-1a hash of the UTF-8 bytes of text, as 16 lowercase hex digits.
export function fnv1a64Hex(text: string): string {
  let hash = FNV_OFFSET
  for (const byte of Buffer.from(text, 'utf8')) {
    hash = ((hash ^ BigInt(byte)) * FNV_PRIME) & U64
  }
  return hash.toString(16).padStart(16, '0')
}

// The folder that holds the sockets whose paths would be too long.
export function shortSocketFolder(uid: number): string {
  return `/tmp/synapse-pipeline-${uid}`
}

// Where the run whose record folder is recordFolder listens: execution.sock in
// that folder when the path fits, else in shortSocketFolder(uid), named by the
// hash of the folder. The same rule as synapse-pipeline's
// Synapse.Pipeline.Socket_Paths and the Rust host's runs.rs; the three must
// give the same path, byte for byte.
export function socketEndpoint(recordFolder: string, uid: number): string {
  const inRecord = join(recordFolder, 'execution.sock')
  return Buffer.byteLength(inRecord, 'utf8') <= MAX_SOCKET_PATH
    ? inRecord
    : `${shortSocketFolder(uid)}/${fnv1a64Hex(recordFolder)}.sock`
}

// The record folder resolved by realpath(3), which realpathSync.native calls
// and plain realpathSync does not: links resolved and each name in its case on
// disk, as synapse-pipeline hashes it. As it is when it cannot be resolved.
function realFolder(folder: string): string {
  try {
    return realpathSync.native(folder)
  } catch {
    return folder
  }
}

// Where the run listens: by socketEndpoint, or a named pipe on Windows.
export function socketPath(recordsDir: string, executionId: string, platform: string): string {
  if (platform === 'win32') return `\\\\.\\pipe\\synapse-pipeline-${executionId}`
  return socketEndpoint(realFolder(join(recordsDir, executionId)), process.getuid?.() ?? 0)
}

// Whether folder is one only this user can use: a directory, not a symbolic
// link, owned by this user, with no permissions for anyone else. A socket in
// the short folder is connected to only then: the folder is in /tmp, where
// another user could have made it to answer in a run's place.
export function isPrivateFolder(folder: string, uid: number): boolean {
  try {
    const stat = lstatSync(folder)
    return stat.isDirectory() && stat.uid === uid && (stat.mode & 0o077) === 0
  } catch {
    return false
  }
}

export class NotListening extends Error {}

// Rejects with NotListening when nothing answers: the run is over, or it died.
export function askRun(path: string, request: unknown): Promise<RunAnswer> {
  if (process.platform !== 'win32') {
    const uid = process.getuid?.() ?? 0
    const short = shortSocketFolder(uid)
    if (dirname(path) === short && !isPrivateFolder(short, uid)) {
      return Promise.reject(new NotListening(`${short} is not a folder only this user can use`))
    }
  }
  return new Promise((resolve, reject) => {
    const socket = createConnection(path)
    const chunks: Buffer[] = []
    let size = 0
    let settled = false

    function finish(action: () => void): void {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.destroy()
      action()
    }

    const timer = setTimeout(
      () => finish(() => reject(new NotListening('the run did not answer in time'))),
      TIMEOUT_MS,
    )

    function answer(): void {
      try {
        const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')) as RunAnswer
        finish(() => resolve(parsed))
      } catch {
        finish(() => reject(new Error('the run sent an answer that is not JSON')))
      }
    }

    socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'))
    socket.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > MAX_ANSWER_BYTES) {
        finish(() => reject(new Error('the answer is too large')))
        return
      }
      chunks.push(chunk)
    })
    socket.on('end', answer)
    socket.on('error', (error) => finish(() => reject(new NotListening(error.message))))
  })
}
