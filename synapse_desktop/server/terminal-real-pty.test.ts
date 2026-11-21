// Real OS PTY smoke test. No AI agent, gateway listener, or remote mode.
// The shell runs a fixed command in a temporary directory and is killed on cleanup.
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { spawnPty, type Pty } from './terminal.ts'

const directories: string[] = []
const processes: Pty[] = []

afterEach(async () => {
  for (const process of processes.splice(0)) {
    try {
      process.kill()
    } catch {
      // The process may already have exited.
    }
  }
  await Promise.all(directories.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe.skipIf(process.platform === 'win32')('real local PTY', () => {
  it('spawns a shell, receives output, accepts input and reports exit', async () => {
    const home = await mkdtemp(join(tmpdir(), 'synapse-real-pty-'))
    directories.push(home)
    const marker = 'SYNAPSE_PTY_SMOKE_OK'
    const shell = '/bin/sh'
    const pty = spawnPty(shell, [], {
      cwd: home,
      env: { PATH: '/usr/bin:/bin', HOME: home, TERM: 'xterm-256color' },
      cols: 80,
      rows: 24,
    })
    processes.push(pty)
    let output = ''
    let exited: number | undefined
    const complete = new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('real PTY shell timed out')), 10_000)
      pty.onExit(({ exitCode }) => {
        exited = exitCode
        clearTimeout(timeout)
        resolve()
      })
    })
    pty.onData((data) => {
      output += data
    })
    pty.write(`printf '%s\\n' '${marker}'\\nexit 0\\n`)
    await complete
    expect(exited).toBe(0)
    expect(output).toContain(marker)
  }, 15_000)
})
