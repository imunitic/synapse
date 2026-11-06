// The local API server of the web phase. It is development tooling and is not
// shipped; Tauri replaces it.

import { randomBytes } from 'node:crypto'
import { createServer } from 'node:http'
import { homedir } from 'node:os'
import { SERVER_PORT, WEB_PORT } from '../shared/constants.ts'
import { runCli } from './cli.ts'
import { configFile } from './config-store.ts'
import { createHandler } from './http.ts'

const environment = { env: process.env, home: homedir() }
const suppliedToken = process.env.SYNAPSE_DESKTOP_TOKEN
const token = suppliedToken ? suppliedToken : randomBytes(24).toString('hex')

const handler = createHandler(
  { environment, configFile: configFile(environment), runCli },
  {
    allowedHosts: new Set([`127.0.0.1:${SERVER_PORT}`, `localhost:${SERVER_PORT}`]),
    allowedOrigins: new Set([`http://127.0.0.1:${WEB_PORT}`, `http://localhost:${WEB_PORT}`]),
    token,
  },
)

createServer((req, res) => void handler(req, res)).listen(SERVER_PORT, '127.0.0.1', () => {
  console.log(`synapse-desktop server on http://127.0.0.1:${SERVER_PORT}`)
  if (!suppliedToken) console.log(`token: ${token}`)
})
