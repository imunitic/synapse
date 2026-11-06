import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { request, createServer, type Server } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { API_PREFIX, TOKEN_HEADER } from '../shared/constants.ts'
import type { CliRun } from './cli.ts'
import { createHandler } from './http.ts'

const TOKEN = 'test-token'
const ORIGIN = 'http://localhost:5173'

let dir: string
let server: Server
let port: number
let cliCalls: CliRun[]

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-http-'))
  cliCalls = []
  const hosts = new Set<string>()
  const handler = createHandler(
    {
      environment: { env: { XDG_CONFIG_HOME: join(dir, 'xdg') }, home: dir },
      configFile: join(dir, 'config.json'),
      runCli: (run) => {
        cliCalls.push(run)
        return Promise.resolve({ code: 0, stdout: 'ok', stderr: '' })
      },
    },
    { allowedHosts: hosts, allowedOrigins: new Set([ORIGIN]), token: TOKEN },
  )
  server = createServer((req, res) => void handler(req, res))
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  port = address.port
  hosts.add(`127.0.0.1:${port}`)
})

afterEach(async () => {
  await new Promise((resolve) => server.close(resolve))
  await rm(dir, { recursive: true, force: true })
})

interface Reply {
  status: number
  body: { ok: boolean; result?: unknown; error?: string }
}

function post(
  method: string,
  params: object,
  headers: Record<string, string> = {},
): Promise<Reply> {
  const all = {
    'content-type': 'application/json',
    origin: ORIGIN,
    [TOKEN_HEADER]: TOKEN,
    ...headers,
  }
  return new Promise((resolve, reject) => {
    const req = request(
      { host: '127.0.0.1', port, path: API_PREFIX + method, method: 'POST', headers: all },
      (res) => {
        let text = ''
        res.on('data', (chunk: Buffer) => (text += chunk.toString()))
        res.on('end', () =>
          resolve({ status: res.statusCode ?? 0, body: JSON.parse(text) as Reply['body'] }),
        )
      },
    )
    req.on('error', reject)
    req.end(JSON.stringify(params))
  })
}

describe('the API', () => {
  it('answers getConfig with the default configuration', async () => {
    const reply = await post('getConfig', {})
    expect(reply.status).toBe(200)
    expect(reply.body.result).toEqual({ workDir: null, definitionPaths: [], defaultHarness: null })
  })

  it('keeps what setConfig stores', async () => {
    await post('setConfig', { patch: { workDir: '/w', defaultHarness: 'Codex' } })
    const reply = await post('getConfig', {})
    expect(reply.body.result).toEqual({
      workDir: '/w',
      definitionPaths: [],
      defaultHarness: 'Codex',
    })
  })

  it('refuses a request without the token, with a foreign Origin or with another Host', async () => {
    expect((await post('getConfig', {}, { [TOKEN_HEADER]: 'nope' })).status).toBe(401)
    expect((await post('getConfig', {}, { origin: 'https://evil.example' })).status).toBe(403)
    expect((await post('getConfig', {}, { host: 'evil.example' })).status).toBe(403)
    expect((await post('getConfig', {}, { 'content-type': 'text/plain' })).status).toBe(415)
  })

  it('refuses an unknown method and invalid parameters', async () => {
    expect((await post('shutdown', {})).status).toBe(404)
    expect((await post('readText', { path: 5 })).status).toBe(400)
  })

  it('reads a definition file and refuses any other file', async () => {
    const definitions = join(dir, 'xdg', 'synapse-pipeline')
    await mkdir(definitions, { recursive: true })
    await writeFile(join(definitions, 'P.synapse'), 'Pipeline P {}')
    await writeFile(join(dir, 'private.txt'), 'secret')

    const ok = await post('readText', { path: join(definitions, 'P.synapse') })
    expect(ok.body.result).toBe('Pipeline P {}')
    expect((await post('readText', { path: join(dir, 'private.txt') })).status).toBe(403)
    expect((await post('readDir', { path: dir })).status).toBe(403)
  })

  it('runs an allowed CLI subcommand and refuses the others without running them', async () => {
    const ok = await post('cli', {
      binary: 'synapse-pipeline',
      args: ['show', 'P', '--format', 'json'],
    })
    expect(ok.body.result).toEqual({ code: 0, stdout: 'ok', stderr: '' })
    expect(cliCalls).toHaveLength(1)

    const refused = await post('cli', { binary: 'synapse-pipeline', args: ['run', 'P'] })
    expect(refused.status).toBe(400)
    expect(cliCalls).toHaveLength(1)
  })

  it('lists only the directories that exist', async () => {
    const definitions = join(dir, 'xdg', 'synapse-pipeline')
    await mkdir(join(definitions, 'skills'), { recursive: true })
    await post('setConfig', {
      patch: { workDir: join(dir, 'work'), definitionPaths: [join(dir, 'missing')] },
    })

    const before = await post('getPaths', {})
    expect(before.body.result).toEqual({
      definitionDirs: [definitions],
      skillsDir: join(definitions, 'skills'),
      recordsDir: null,
    })

    await mkdir(join(dir, 'work', 'pipelines'), { recursive: true })
    const after = await post('getPaths', {})
    expect(after.body.result).toMatchObject({ recordsDir: join(dir, 'work', 'pipelines') })
  })

  it('refuses a run id that would leave the records directory', async () => {
    await post('setConfig', { patch: { workDir: join(dir, 'work') } })
    const reply = await post('runRequest', { executionId: '../x', request: { command: 'info' } })
    expect(reply.status).toBe(400)
  })

  it('reports a run that is not listening, and no work directory', async () => {
    const none = await post('runRequest', { executionId: 'exec-1', request: { command: 'info' } })
    expect(none.status).toBe(409)

    await post('setConfig', { patch: { workDir: join(dir, 'work') } })
    const gone = await post('runRequest', { executionId: 'exec-1', request: { command: 'info' } })
    expect(gone.status).toBe(404)
  })
})
