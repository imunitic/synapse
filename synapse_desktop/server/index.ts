// The local API server of the web phase. It is development tooling and is not
// shipped; Tauri replaces it.

import { randomBytes } from 'node:crypto'
import { createServer } from 'node:http'
import { homedir } from 'node:os'
import { SERVER_PORT, WEB_PORT } from '../shared/constants.ts'
import { runCli } from './cli.ts'
import { configFile } from './config-store.ts'
import { createHandler } from './http.ts'
import { runAgent } from './generate.ts'
import { createNoteSession } from './note-agent.ts'
import { createRunStarter } from './runs.ts'
import { attachTerminals, defaultPlan, sessionsRoot, spawnPty } from './terminal.ts'

const environment = { env: process.env, home: homedir() }
const suppliedToken = process.env.SYNAPSE_DESKTOP_TOKEN
const token = suppliedToken ? suppliedToken : randomBytes(24).toString('hex')

const policy = {
  allowedHosts: new Set([`127.0.0.1:${SERVER_PORT}`, `localhost:${SERVER_PORT}`]),
  allowedOrigins: new Set([`http://127.0.0.1:${WEB_PORT}`, `http://localhost:${WEB_PORT}`]),
  token,
}

const context = {
  environment,
  configFile: configFile(environment),
  runCli,
  agent: runAgent,
  runs: createRunStarter('synapse-pipeline', process.env),
  noteSession: createNoteSession((harness) => defaultPlan(environment)(harness)),
}

const handler = createHandler(context, policy)

const server = createServer((req, res) => void handler(req, res))
attachTerminals(server, {
  policy,
  environment,
  configFile: context.configFile,
  spawn: spawnPty,
  plan: defaultPlan(environment),
  maxTerminals: 8,
  sessionsRoot: sessionsRoot(environment),
})
server.listen(SERVER_PORT, '127.0.0.1', () => {
  console.log(`synapse-desktop server on http://127.0.0.1:${SERVER_PORT}`)
  if (!suppliedToken) console.log(`token: ${token}`)
})
