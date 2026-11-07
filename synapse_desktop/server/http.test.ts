import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { request, createServer, type Server } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { API_PREFIX, TOKEN_HEADER } from '../shared/constants.ts'
import type { CliRun } from './cli.ts'
import { createHandler } from './http.ts'
import { NotStartedHere, RunNotStarted } from './runs.ts'

const TOKEN = 'test-token'
const ORIGIN = 'http://localhost:5173'

let dir: string
let server: Server
let port: number
let cliCalls: CliRun[]
let cliResult: { code: number; stdout: string; stderr: string }

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-http-'))
  cliCalls = []
  cliResult = { code: 0, stdout: 'ok', stderr: '' }
  const hosts = new Set<string>()
  const handler = createHandler(
    {
      environment: { env: { XDG_CONFIG_HOME: join(dir, 'xdg') }, home: dir },
      configFile: join(dir, 'config.json'),
      runs: {
        start: () => Promise.reject(new RunNotStarted('stub')),
        stop: () => {
          throw new NotStartedHere('stub')
        },
      },
      agent: () => Promise.reject(new Error('not used')),
      runCli: (run) => {
        cliCalls.push(run)
        return Promise.resolve(cliResult)
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
    expect(reply.body.result).toEqual({
      // Nothing names a work directory, so it is the default in the home.
      workDir: join(dir, '.cache', 'synapse', 'work'),
      definitionPaths: [],
      defaultHarness: null,
      env: {},
      recentVaults: [],
      terminalFolder: null,
    })
  })

  it('installs Synapse and the pipeline skills for a harness, each with its own content', async () => {
    const reply = await post('configureHarness', { harness: 'Codex' })
    expect(reply.status).toBe(200)
    expect(cliCalls.map((c) => [c.binary, c.args])).toEqual([
      ['synapse', ['configure', 'codex']],
      ['synapse-pipeline', ['configure', 'codex']],
    ])
    const [first, second] = cliCalls
    expect(first?.env?.SYNAPSE_CONTENT_ROOT).toMatch(/packages[\\/]synapse$/)
    expect(second?.env?.SYNAPSE_CONTENT_ROOT).toMatch(/packages[\\/]synapse-pipeline$/)
  })

  it('refuses a harness it does not know, and reports a configure that failed', async () => {
    expect((await post('configureHarness', { harness: 'Cursor' })).status).toBe(400)
    cliResult = { code: 1, stdout: '', stderr: 'synapse-configure: no home' }
    const failed = await post('configureHarness', { harness: 'Claude' })
    expect(failed.status).toBe(502)
    expect(failed.body.error).toContain('no home')
  })

  it('says what each harness has installed', async () => {
    const reply = await post('getIntegrations', {})
    expect(reply.status).toBe(200)
    const result = reply.body.result as { harnesses: { harness: string; state: string }[] }
    expect(result.harnesses.map((h) => h.harness)).toEqual(['Claude', 'Codex', 'Opencode'])
  })

  it('keeps what setConfig stores', async () => {
    await post('setConfig', { patch: { workDir: '/w', defaultHarness: 'Codex' } })
    const reply = await post('getConfig', {})
    expect(reply.body.result).toEqual({
      workDir: '/w',
      definitionPaths: [],
      defaultHarness: 'Codex',
      env: {},
      recentVaults: [],
      terminalFolder: null,
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

  it('reports a run that is not listening, in the work directory there is by default', async () => {
    const gone = await post('runRequest', { executionId: 'exec-1', request: { command: 'info' } })
    expect(gone.status).toBe(404)

    await post('setConfig', { patch: { workDir: join(dir, 'work') } })
    const still = await post('runRequest', { executionId: 'exec-1', request: { command: 'info' } })
    expect(still.status).toBe(404)
  })
})
