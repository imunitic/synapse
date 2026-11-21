// Opt-in, loopback-only Chromium smoke test for the detached private gateway.
// Requires `npm run build` and `npx playwright install chromium`.
// Does NOT enable remote host mode, contact the VPS or start a public listener.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { join } from 'node:path'
import { chromium } from '@playwright/test'
import { WebSocketServer } from 'ws'
import { BUS_PATH, TOKEN_HEADER } from '../shared/constants.ts'
import { attachPrivateGateway } from '../server/gateway-private-entry.ts'
import { hashGatewayPassword } from '../server/gateway-password-verifier.ts'
import { createGatewaySessions } from '../server/gateway-sessions.ts'
import { loadViteProtectedAssets } from '../server/gateway-vite-assets.ts'

const assets = await loadViteProtectedAssets(join(import.meta.dirname, '..', 'dist'))
const scriptPath = [...assets.keys()].find(
  (path) => path.startsWith('/assets/') && path.endsWith('.js'),
)
assert.ok(scriptPath, 'missing production JavaScript bundle')

const backendToken = 'browser-test-internal-credential'
const backendOrigin = 'http://gateway.internal'
const backend = createServer((_request, response) => response.writeHead(404).end())
const backendSockets = new WebSocketServer({ noServer: true })
let backendConnections = 0
const fakeTerminals = new Map<string, Record<string, unknown>>()
const terminalScreens = new Map<string, string>()
let terminalStarts = 0
let terminalAttaches = 0
backend.on('upgrade', (request, socket, head) => {
  if (
    request.url !== BUS_PATH ||
    request.headers[TOKEN_HEADER] !== backendToken ||
    request.headers.origin !== backendOrigin ||
    request.headers.cookie !== undefined
  ) {
    socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n')
    return
  }
  backendSockets.handleUpgrade(request, socket, head, (ws) => {
    backendConnections++
    ws.send(
      JSON.stringify({
        kind: 'hello',
        protocol: 1,
        capabilities: { host: 'node', shell: true, installActions: false },
      }),
    )
    ws.on('message', (data, binary) => {
      if (binary) return
      let message: unknown
      try {
        message = JSON.parse(data.toString()) as unknown
      } catch {
        return
      }
      if (!message || typeof message !== 'object') return
      const received = message as {
        kind?: string
        id?: string
        name?: string
        session?: string
        params?: { session?: string; title?: string; kind?: string }
        data?: { type?: string; data?: string }
      }
      if (received.kind === 'request' && received.id) {
        let result: unknown = null
        if (received.name === 'config.get') {
          result = {
            config: {
              workDir: null,
              definitionPaths: [],
              defaultHarness: null,
              defaultModels: {},
              env: {},
              recentVaults: [],
              terminalFolder: null,
              graphRepos: {},
            },
            paths: { definitionDirs: [], skillsDir: null, recordsDir: null },
          }
        } else if (received.name === 'terminal.list') {
          result = { sessions: [...fakeTerminals.values()] }
        } else if (received.name === 'terminal.start' && received.params?.session) {
          terminalStarts++
          const terminal = {
            session: received.params.session,
            title: received.params.title ?? 'Shell',
            kind: 'Shell',
            cwd: '/tmp',
            loaded: false,
            note: '',
            exited: null,
          }
          fakeTerminals.set(terminal.session, terminal)
          terminalScreens.set(terminal.session, 'Synapse PWA terminal ready\r\n')
          result = terminal
        } else if (received.name === 'terminal.attach' && received.params?.session) {
          terminalAttaches++
          result = fakeTerminals.get(received.params.session) ?? null
        } else if (received.name === 'terminal.close' && received.params?.session) {
          fakeTerminals.delete(received.params.session)
          terminalScreens.delete(received.params.session)
        } else if (received.name === 'changes.snapshot') {
          ws.send(
            JSON.stringify({
              kind: 'reply',
              id: received.id,
              error: { code: 'unavailable', message: 'test snapshot unavailable' },
            }),
          )
          return
        }
        ws.send(JSON.stringify({ kind: 'reply', id: received.id, result }))
        if (received.name === 'terminal.start' && received.params?.session) {
          ws.send(
            JSON.stringify({
              kind: 'stream',
              session: received.params.session,
              data: {
                type: 'output',
                data: terminalScreens.get(received.params.session) ?? '',
              },
            }),
          )
        }
        if (received.name === 'terminal.attach' && received.params?.session) {
          ws.send(
            JSON.stringify({
              kind: 'stream',
              session: received.params.session,
              data: {
                type: 'snapshot',
                data: terminalScreens.get(received.params.session) ?? '',
              },
            }),
          )
        }
        return
      }
      if (
        received.kind === 'stream' &&
        received.session &&
        received.data?.type === 'input' &&
        typeof received.data.data === 'string'
      ) {
        if (!terminalScreens.has(received.session)) return
        terminalScreens.set(
          received.session,
          (terminalScreens.get(received.session) ?? '') + received.data.data,
        )
        ws.send(
          JSON.stringify({
            kind: 'stream',
            session: received.session,
            data: { type: 'output', data: received.data.data },
          }),
        )
        return
      }
      ws.send(data.toString())
    })
  })
})

const server = createServer()
let browser: Awaited<ReturnType<typeof chromium.launch>> | undefined
try {
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('invalid loopback address')
  const origin = `http://127.0.0.1:${address.port}`
  await new Promise<void>((resolve) => backend.listen(0, '127.0.0.1', resolve))
  const backendAddress = backend.address()
  if (!backendAddress || typeof backendAddress === 'string') {
    throw new Error('invalid test backend address')
  }
  const sessions = createGatewaySessions()
  attachPrivateGateway(server, {
    publicHost: `127.0.0.1:${address.port}`,
    publicOrigin: origin,
    sessions,
    accounts: [
      {
        username: 'browser-test',
        userId: 'browser-test',
        passwordHash: await hashGatewayPassword('browser-test-only-password'),
      },
    ],
    hosts: new Map([
      [
        'browser-test',
        {
          userId: 'browser-test',
          backend: `http://127.0.0.1:${backendAddress.port}`,
          backendToken,
          backendOrigin,
        },
      ],
    ]),
    recheckMs: 50,
    assets,
  })

  browser = await chromium.launch({ headless: true })
  const context = await browser.newContext()
  try {
    const page = await context.newPage()
    const pageErrors: string[] = []
    page.on('pageerror', (error) => pageErrors.push(error.message))
    const beforeLogin = await context.request.get(`${origin}${scriptPath}`)
    assert.equal(beforeLogin.status(), 401, 'production bundle leaked before sign-in')
    await page.goto(origin, { waitUntil: 'domcontentloaded' })
    await page.locator('#login-form').waitFor()
    assert.equal(new URL(page.url()).pathname, '/login')
    await page.locator('#username').fill('browser-test')
    await page.locator('#password').fill('browser-test-only-password')
    await page.getByRole('button', { name: 'Sign in' }).click()
    await page.locator('.shell').waitFor({ timeout: 15_000 })
    assert.equal(new URL(page.url()).pathname, '/', 'login did not reach protected app')
    const bundle = await context.request.get(`${origin}${scriptPath}`)
    assert.equal(bundle.status(), 200, 'authenticated browser cannot fetch its JS')
    assert.match(
      bundle.headers()['content-security-policy'] ?? '',
      /default-src 'self'/,
      'protected bundle is missing CSP',
    )
    // Exercise the actual React terminal component and xterm.js DOM using
    // the protected gateway and a deterministic protocol-level fake backend.
    await page.getByRole('button', { name: 'New shell' }).click()
    const terminalHost = page.locator('.terminal-host').first()
    await terminalHost.locator('.xterm-screen').waitFor({ timeout: 15_000 })
    await page.waitForFunction(() =>
      [...document.querySelectorAll('.xterm-rows')].some((element) =>
        element.textContent?.includes('Synapse PWA terminal ready'),
      ),
    )
    await terminalHost.locator('.xterm-helper-textarea').focus()
    await page.keyboard.type('browser-input-check')
    await page.waitForFunction(() =>
      [...document.querySelectorAll('.xterm-rows')].some((element) =>
        element.textContent?.includes('browser-input-check'),
      ),
    )
    // A browser reload must adopt the server-held terminal instead of
    // starting a duplicate. Its xterm.js view must restore the snapshot.
    assert.equal(terminalStarts, 1, 'unexpected number of terminal starts before reload')
    await page.reload({ waitUntil: 'domcontentloaded' })
    await page.locator('.shell').waitFor()
    await page.locator('section[aria-label="Running now"] button').last().click()
    await page.locator('.terminal-host .xterm-screen').first().waitFor()
    await page.waitForFunction(() =>
      [...document.querySelectorAll('.xterm-rows')].some((element) =>
        element.textContent?.includes('browser-input-check'),
      ),
    )
    assert.equal(terminalStarts, 1, 'browser reload started a duplicate terminal')
    assert.equal(fakeTerminals.size, 1, 'browser reload lost its existing terminal')
    assert.ok(terminalAttaches > 0, 'browser reload did not reattach to its terminal')
    // Check that typing still works after restoration, not just that the old
    // screen can be displayed.
    await page.locator('.terminal-host .xterm-helper-textarea').first().focus()
    await page.keyboard.type('after-reload-check')
    await page.waitForFunction(() =>
      [...document.querySelectorAll('.xterm-rows')].some((element) =>
        element.textContent?.includes('after-reload-check'),
      ),
    )
    assert.equal(fakeTerminals.size, 1, 'continued input created a second terminal')
    assert.deepEqual(pageErrors, [], 'uncaught page errors during application mount')
    // Exercise the real browser WebSocket path, with a private backend that
    // refuses direct access and requires a gateway-owned credential.
    const relay = page.evaluate(
      () =>
        new Promise<string>((resolve, reject) => {
          const socket = new WebSocket(`ws://${location.host}/api/bus`)
          const timeout = setTimeout(() => {
            socket.close()
            reject(new Error('gateway WebSocket echo timed out'))
          }, 5000)
          socket.onopen = () => socket.send(JSON.stringify({ kind: 'browser-smoke' }))
          socket.onmessage = (event) => {
            try {
              const message: unknown = JSON.parse(String(event.data))
              if (
                !message ||
                typeof message !== 'object' ||
                (message as { kind?: string }).kind !== 'browser-smoke'
              ) {
                return
              }
            } catch {
              return
            }
            clearTimeout(timeout)
            socket.close()
            resolve(String(event.data))
          }
          socket.onerror = () => {
            clearTimeout(timeout)
            reject(new Error('gateway WebSocket connection failed'))
          }
        }),
    )
    assert.deepEqual(JSON.parse(await relay), { kind: 'browser-smoke' })
    assert.ok(backendConnections > 0, 'authenticated browser did not reach its private backend')
    // A logged-out browser must lose an *already open* gateway connection,
    // not just access to new upgrades and protected HTTP assets.
    const revokedSocket = await page.evaluate(async () => {
      const socket = new WebSocket(`ws://${location.host}/api/bus`)
      await new Promise<void>((resolve, reject) => {
        socket.onopen = () => resolve()
        socket.onerror = () => reject(new Error('WebSocket failed before logout'))
      })
      const closed = new Promise<void>((resolve, reject) => {
        const deadline = setTimeout(() => {
          socket.close()
          reject(new Error('revoked WebSocket remained open'))
        }, 5000)
        socket.onclose = () => {
          clearTimeout(deadline)
          resolve()
        }
      })
      const response = await fetch('/auth/logout', {
        method: 'POST',
        credentials: 'same-origin',
      })
      if (response.status !== 200) throw new Error(`logout returned ${response.status}`)
      await closed
      return response.status
    })
    assert.equal(revokedSocket, 200)
    await page.goto(origin, { waitUntil: 'domcontentloaded' })
    await page.locator('#login-form').waitFor()
    assert.equal(new URL(page.url()).pathname, '/login', 'logout did not revoke page access')
    assert.equal(
      (await context.request.get(`${origin}${scriptPath}`)).status(),
      401,
      'logout did not revoke access to the bundle',
    )
    console.log('Chromium: protected production UI mounted, logout revoked access')
  } finally {
    await context.close()
  }
} finally {
  await browser?.close()
  server.closeAllConnections()
  await new Promise<void>((resolve) => server.close(() => resolve()))
  for (const socket of backendSockets.clients) socket.terminate()
  backend.closeAllConnections()
  await new Promise<void>((resolve) => backend.close(() => resolve()))
}
