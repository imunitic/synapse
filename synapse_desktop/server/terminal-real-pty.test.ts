// Real OS PTY smoke test. No AI agent, gateway listener, or remote mode.
// The shell runs a fixed command in a temporary directory and is killed on cleanup.
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { spawnPty, type Pty } from './terminal.ts'
import { createSessions, type Sink } from './terminal-sessions.ts'

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
    pty.write(`printf '%s\\n' '${marker}'\nexit 0\n`)
    await complete
    expect(exited).toBe(0)
    expect(output).toContain(marker)
  }, 15_000)
  it('preserves a real shell across detach and reattach with a screen snapshot', async () => {
    const home = await mkdtemp(join(tmpdir(), 'synapse-pty-reconnect-'))
    directories.push(home)
    const configFile = join(home, 'config.json')
    const sessions = createSessions({
      environment: { env: { PATH: '/usr/bin:/bin', HOME: home, SHELL: '/bin/sh' }, home },
      configFile,
      sessionsRoot: join(home, 'sessions'),
      maxTerminals: 1,
      plan: async () => ({
        command: '/bin/sh',
        args: [],
        env: {},
        loaded: false,
        note: '',
      }),
      spawn: (file, args, options) => {
        const pty = spawnPty(file, args, options)
        processes.push(pty)
        return pty
      },
      watch: () => ({
        stop: () => undefined,
        poll: async () => undefined,
        register: () => undefined,
      }),
    })
    const initial: string[] = []
    const first: Sink = {
      send: (_id, message) => {
        if (message.type === 'output') initial.push(message.data)
      },
    }
    const sessionId = 'real-pty-reconnect'
    await sessions.start(
      { session: sessionId, title: 'Shell', kind: 'Shell', cwd: home, cols: 80, rows: 24 },
      'owner',
      first,
    )
    const marker = 'SYNAPSE_RECONNECT_MARKER'
    sessions.input(sessionId, 'owner', first, `printf '%s\\n' '${marker}'\n`)
    await expect.poll(() => initial.join('')).toContain(marker)
    sessions.detachAll(first)
    const restored: string[] = []
    const second: Sink = {
      send: (_id, message) => {
        if (message.type === 'snapshot') restored.push(message.data)
      },
    }
    sessions.attach(sessionId, 'owner', second, { cols: 80, rows: 24 })
    await expect.poll(() => restored.join('')).toContain(marker)
    // The reattached sink must be able to continue controlling the same real PTY.
    const continued: string[] = []
    const nextMarker = 'SYNAPSE_REATTACHED_INPUT'
    const originalSend = second.send
    second.send = (id, message) => {
      originalSend(id, message)
      if (message.type === 'output') continued.push(message.data)
    }
    sessions.input(sessionId, 'owner', second, `printf '%s\\n' '${nextMarker}'\n`)
    await expect.poll(() => continued.join('')).toContain(nextMarker)
    expect(sessions.list('owner')).toHaveLength(1)
    expect(sessions.list('other')).toHaveLength(0)
    expect(() => sessions.attach(sessionId, 'other', second, { cols: 80, rows: 24 })).toThrow(
      'the session belongs to another user',
    )
    expect(() => sessions.input(sessionId, 'other', second, 'exit 1\\n')).toThrow(
      'the session belongs to another user',
    )
    expect(() => sessions.resize(sessionId, 'other', second, 20, 10)).toThrow(
      'the session belongs to another user',
    )
    expect(() => sessions.close(sessionId, 'other')).toThrow('the session belongs to another user')
    // Denied operations must not kill or corrupt the owner's live PTY.
    const stillAlive = 'SYNAPSE_OWNER_STILL_ACTIVE'
    sessions.input(sessionId, 'owner', second, `printf '%s\\n' '${stillAlive}'\n`)
    await expect.poll(() => continued.join('')).toContain(stillAlive)
    sessions.close(sessionId, 'owner')
  }, 15_000)
})
