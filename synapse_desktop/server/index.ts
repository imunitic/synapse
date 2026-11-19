// The Node host of the served build: it serves the bus on a WebSocket and nothing else.

import { randomBytes } from 'node:crypto'
import { createServer } from 'node:http'
import { homedir } from 'node:os'
import { BUS_PATH } from '../shared/constants.ts'
import { ports } from '../shared/ports.ts'
import { runCli } from './cli.ts'
import { configFile } from './config-store.ts'
import { attachBus } from './bus.ts'
import { dropUnclaimedUpgrades } from './upgrade.ts'
import { runAgent } from './generate.ts'
import { createModelStore, modelCacheFile } from './model-store.ts'
import { createNoteSession } from './note-agent.ts'
import { createRunStarter } from './runs.ts'
import { defaultPlan, sessionsRoot, spawnPty } from './terminal.ts'
import { createSessions } from './terminal-sessions.ts'
import { requireSupportedHostMode } from './host-mode.ts'

requireSupportedHostMode(process.env)

const { web: WEB_PORT, server: SERVER_PORT } = ports(process.env)
const environment = { env: process.env, home: homedir() }
const suppliedToken = process.env.SYNAPSE_DESKTOP_TOKEN
const token = suppliedToken ? suppliedToken : randomBytes(24).toString('hex')

const policy = {
  allowedHosts: new Set([`127.0.0.1:${SERVER_PORT}`, `localhost:${SERVER_PORT}`]),
  allowedOrigins: new Set([`http://127.0.0.1:${WEB_PORT}`, `http://localhost:${WEB_PORT}`]),
  token,
}

const models = createModelStore({ file: modelCacheFile(environment), env: process.env })

const context = {
  environment,
  models,
  configFile: configFile(environment),
  runCli,
  agent: runAgent,
  runs: createRunStarter('synapse-pipeline', process.env),
  noteSession: createNoteSession((harness) => defaultPlan(environment)(harness)),
}

// Everything but the bus and the terminals is refused: the host has no HTTP interface.
const server = createServer((_req, res) => {
  res.writeHead(404, { 'content-type': 'text/plain' })
  res.end('not found')
})
dropUnclaimedUpgrades(server, [BUS_PATH])
const sessions = createSessions({
  environment,
  configFile: context.configFile,
  spawn: spawnPty,
  plan: defaultPlan(environment),
  maxTerminals: 8,
  sessionsRoot: sessionsRoot(environment),
})
attachBus(server, { policy, context, sessions })
server.listen(SERVER_PORT, '127.0.0.1', () => {
  console.log(`synapse-desktop server on http://127.0.0.1:${SERVER_PORT}`)
  // The models of the harnesses are read again, behind whatever is kept of them.
  void models.refreshAll()
  if (!suppliedToken) console.log(`token: ${token}`)
})
