// Stopping the Node host ends everything it started: the processes of its terminal sessions and of
// the runs it started. The test starts a host of its own beside the shared one, on a port of its
// own, so that it can stop it without stopping the suite's.

import { type ChildProcess, execFileSync, spawn } from 'node:child_process'
import { createServer } from 'node:net'
import { join } from 'node:path'
import { WebSocket } from 'ws'
import { BUS_PATH, E2E_WEB_PORT, TOKEN_HEADER } from '../shared/constants.ts'
import { expect, test } from './fixtures.ts'

const TOKEN = 'quit-test-token'

type Message = {
  kind: string
  id?: string
  result?: unknown
  error?: { code: string; message: string }
  session?: string
  data?: { type?: string; data?: string }
}

// A port nothing listens on now.
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      if (address === null || typeof address === 'string') return reject(new Error('no port'))
      server.close(() => resolve(address.port))
    })
  })
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

// Every process and its group, with its command line.
function processes(): { pid: number; pgid: number; command: string }[] {
  const listed = execFileSync('ps', ['-A', '-o', 'pid=,pgid=,command='], { encoding: 'utf8' })
  return listed
    .split('\n')
    .map((line) => /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line))
    .filter((match) => match !== null)
    .map((match) => ({ pid: Number(match[1]), pgid: Number(match[2]), command: match[3] ?? '' }))
}

// Connects to the host's bus, retrying until the host listens.
async function connect(port: number): Promise<WebSocket> {
  const deadline = Date.now() + 15_000
  for (;;) {
    const socket = new WebSocket(`ws://127.0.0.1:${port}${BUS_PATH}`, {
      headers: { origin: `http://127.0.0.1:${E2E_WEB_PORT}`, [TOKEN_HEADER]: TOKEN },
    })
    const opened = await new Promise<boolean>((resolve) => {
      socket.once('open', () => resolve(true))
      socket.once('error', () => resolve(false))
    })
    if (opened) return socket
    if (Date.now() > deadline) throw new Error('the host did not start listening')
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
}

test.skip(process.platform === 'win32', 'process groups and signals are Unix only')

test('stopping the host ends its terminal sessions and the runs it started', async () => {
  test.setTimeout(60_000)
  const port = await freePort()
  const home = process.env.E2E_HOME ?? ''
  const host: ChildProcess = spawn(process.execPath, [join('server', 'index.ts')], {
    cwd: join(import.meta.dirname, '..'),
    // The world's environment, with the home and data folder the shared host has. The shell is
    // bash, which passes the SIGHUP it gets on to its jobs, as zsh does; dash does not.
    env: {
      ...process.env,
      HOME: home,
      USERPROFILE: home,
      XDG_DATA_HOME: process.env.E2E_DATA ?? '',
      SHELL: '/bin/bash',
      SYNAPSE_DESKTOP_E2E: '1',
      SYNAPSE_DESKTOP_SERVER_PORT: String(port),
      SYNAPSE_DESKTOP_TOKEN: TOKEN,
    },
    stdio: 'ignore',
  })
  const exited = new Promise<number | null>((resolve) => host.once('exit', (code) => resolve(code)))
  const pids: number[] = []
  try {
    const socket = await connect(port)
    let output = ''
    const replies = new Map<string, (message: Message) => void>()
    socket.on('message', (raw) => {
      const message = JSON.parse(String(raw)) as Message
      if (message.kind === 'reply' && message.id !== undefined) replies.get(message.id)?.(message)
      if (message.kind === 'stream' && message.data?.type === 'output') {
        output += message.data.data ?? ''
      }
    })
    let next = 0
    const ask = (name: string, params: object) =>
      new Promise<Message>((resolve) => {
        const id = `q${next++}`
        replies.set(id, resolve)
        socket.send(JSON.stringify({ kind: 'request', id, name, params }))
      })

    // A shell that starts a process in the background and says its pid.
    const started = await ask('terminal.start', {
      session: 'quit-shell',
      title: 'Shell',
      kind: 'Shell',
      cols: 80,
      rows: 24,
    })
    expect(started.error).toBeUndefined()
    socket.send(
      JSON.stringify({
        kind: 'stream',
        session: 'quit-shell',
        data: { type: 'input', data: 'sleep 60 & echo "BG=$!=GB"\r' },
      }),
    )
    await expect.poll(() => /BG=(\d+)=GB/.exec(output)?.[1], { timeout: 15_000 }).toBeDefined()
    const background = Number(/BG=(\d+)=GB/.exec(output)?.[1])
    expect(isAlive(background)).toBe(true)
    pids.push(background)

    // A run whose step holds for two minutes, and the processes of its group.
    const run = await ask('run.start', { pipeline: 'Held_Run', input: null })
    expect(run.error).toBeUndefined()
    const { executionId } = run.result as { executionId: string }
    const leader = processes().find(
      (p) => p.command.includes('synapse-pipeline') && p.command.includes(executionId),
    )
    expect(leader).toBeDefined()
    const group = processes().filter((p) => p.pgid === leader?.pid)
    expect(group.length).toBeGreaterThan(0)
    pids.push(...group.map((p) => p.pid))
    socket.close()

    // Stopping the host ends all of them, on time.
    const stoppedAt = Date.now()
    host.kill('SIGTERM')
    const code = await Promise.race([
      exited,
      new Promise<'late'>((resolve) => setTimeout(() => resolve('late'), 5_000)),
    ])
    expect(code).toBe(0)
    expect(Date.now() - stoppedAt).toBeLessThan(5_000)
    // A process just signalled may take a moment to be reaped.
    await expect.poll(() => pids.filter(isAlive), { timeout: 2_000 }).toEqual([])
  } finally {
    // Whatever the test found, nothing of it stays behind.
    if (host.exitCode === null) host.kill('SIGKILL')
    for (const pid of pids) {
      try {
        process.kill(pid, 'SIGKILL')
      } catch {
        // already gone
      }
    }
  }
})
