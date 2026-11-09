// Starts the API server and the Vite dev server with one per-launch token. The
// server restarts itself when one of its files changes, keeping the token.

import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'

const env = { ...process.env, SYNAPSE_DESKTOP_TOKEN: randomBytes(24).toString('hex') }

const children = [
  spawn(process.execPath, ['--watch', 'server/index.ts'], { env, stdio: 'inherit' }),
  spawn(process.execPath, ['node_modules/vite/bin/vite.js'], { env, stdio: 'inherit' }),
]

function stopAll(): void {
  for (const child of children) child.kill()
}

// Either one ending ends the other; the exit code is the first one's.
for (const child of children) {
  child.on('exit', (code) => {
    stopAll()
    process.exitCode ??= code ?? 1
  })
}
process.on('SIGINT', stopAll)
process.on('SIGTERM', stopAll)
