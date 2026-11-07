// Asking a running pipeline about itself over its socket (a named pipe on
// Windows): one JSON request ended by a line feed, one JSON answer.

import { createConnection } from 'node:net'
import { join } from 'node:path'
import type { RunAnswer } from '../shared/transport.ts'

const TIMEOUT_MS = 3000
const MAX_ANSWER_BYTES = 2 * 1024 * 1024

// Where the run listens: execution.sock in its record directory, or a named
// pipe on Windows.
export function socketPath(recordsDir: string, executionId: string, platform: string): string {
  return platform === 'win32'
    ? `\\\\.\\pipe\\synapse-pipeline-${executionId}`
    : join(recordsDir, executionId, 'execution.sock')
}

export class NotListening extends Error {}

// Rejects with NotListening when nothing answers: the run is over, or it died.
export function askRun(path: string, request: unknown): Promise<RunAnswer> {
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
