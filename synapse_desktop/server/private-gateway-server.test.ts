// Process-level smoke test for the actual opt-in gateway executable.
// Synthetic accounts and a disposable Vite fixture; no VPS or external listener.
import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { hashGatewayPassword } from './gateway-password-verifier.ts'

const children: ChildProcess[] = []
const directories: string[] = []

async function freePort(): Promise<number> {
  const server = createServer()
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('invalid test address')
  const port = address.port
  await new Promise<void>((resolve) => server.close(() => resolve()))
  return port
}

afterEach(async () => {
  for (const child of children.splice(0)) child.kill()
  await Promise.all(directories.splice(0).map((path) => rm(path, { recursive: true, force: true })))
})

describe('private gateway executable', () => {
  it('serves protected assets only after authenticating with fixture credentials', async () => {
    const root = await mkdtemp(join(tmpdir(), 'synapse-gateway-process-'))
    directories.push(root)
    const dist = join(root, 'dist')
    await mkdir(join(dist, '.vite'), { recursive: true })
    await mkdir(join(dist, 'assets'), { recursive: true })
    await writeFile(
      join(dist, '.vite', 'manifest.json'),
      JSON.stringify({ 'index.html': { file: 'assets/main.js' } }),
    )
    await writeFile(
      join(dist, 'index.html'),
      '<html><script src="/assets/main.js"></script></html>',
    )
    await writeFile(join(dist, 'assets', 'main.js'), 'console.log("fixture")')
    const port = await freePort()
    const backendPort = await freePort()
    const origin = 'https://synapse.example.test'
    const configPath = join(root, 'gateway.json')
    await writeFile(
      configPath,
      JSON.stringify({
        port,
        publicHost: 'synapse.example.test',
        publicOrigin: origin,
        buildDirectory: dist,
        accounts: [
          {
            username: 'fixture',
            userId: 'fixture',
            passwordHash: await hashGatewayPassword('fixture-password-long'),
          },
        ],
        hosts: [
          {
            userId: 'fixture',
            backend: `http://127.0.0.1:${backendPort}`,
            backendToken: 'fixture-backend-token',
            backendOrigin: 'http://gateway.internal',
          },
        ],
      }),
    )
    const child = spawn(process.execPath, ['server/private-gateway-server.ts'], {
      cwd: join(import.meta.dirname, '..'),
      env: { ...process.env, SYNAPSE_PRIVATE_GATEWAY_CONFIG: configPath },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    children.push(child)
    let output = ''
    child.stdout?.on('data', (chunk: Buffer) => { output += chunk.toString() })
    child.stderr?.on('data', (chunk: Buffer) => { output += chunk.toString() })
    let lastStatus = 0
    const url = `http://127.0.0.1:${port}`
    let ready = false
    for (let attempt = 0; attempt < 100; attempt++) {
      if (child.exitCode !== null) throw new Error('private gateway exited before becoming ready')
      try {
        const response = await fetch(`${url}/login`, { headers: { Host: 'synapse.example.test' } })
        lastStatus = response.status
        if (response.status === 200) {
          ready = true
          break
        }
      } catch {
        /* listener not yet ready */
      }
      await new Promise((resolve) => setTimeout(resolve, 50))
    }
    expect(ready, `gateway readiness failed: HTTP ${lastStatus}; child output: ${output}`).toBe(true)
    expect((await fetch(url, { headers: { Host: 'synapse.example.test' } })).status).toBe(401)
    expect(
      (await fetch(`${url}/assets/main.js`, { headers: { Host: 'synapse.example.test' } })).status,
    ).toBe(401)
    const login = await fetch(`${url}/auth/session`, {
      method: 'POST',
      headers: { Host: 'synapse.example.test', Origin: origin, 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'fixture', password: 'fixture-password-long' }),
    })
    expect(login.status).toBe(200)
    const cookie = login.headers.get('set-cookie')?.split(';')[0]
    expect(cookie).toBeTruthy()
    expect(
      (await fetch(url, { headers: { Host: 'synapse.example.test', Cookie: cookie ?? '' } }))
        .status,
    ).toBe(200)
    expect(
      (
        await fetch(`${url}/assets/main.js`, {
          headers: { Host: 'synapse.example.test', Cookie: cookie ?? '' },
        })
      ).status,
    ).toBe(200)
  }, 20_000)
})
