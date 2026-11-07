// The HTTP face of the API: POST /api/call/<method> with a JSON body.

import type { IncomingMessage, ServerResponse } from 'node:http'
import { API_PREFIX, TOKEN_HEADER } from '../shared/constants.ts'
import { CallError, handleCall, type Context } from './calls.ts'
import { checkRequest, type Policy } from './guards.ts'

const MAX_BODY_BYTES = 1024 * 1024

function send(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of req) {
    size += (chunk as Buffer).length
    if (size > MAX_BODY_BYTES) throw new CallError('request body is too large', 413)
    chunks.push(chunk as Buffer)
  }
  return Buffer.concat(chunks).toString('utf8')
}

function header(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name]
  return Array.isArray(value) ? value[0] : value
}

export function createHandler(
  context: Context,
  policy: Policy,
): (req: IncomingMessage, res: ServerResponse) => Promise<void> {
  return async (req, res) => {
    try {
      const url = req.url ?? ''
      if (req.method !== 'POST' || !url.startsWith(API_PREFIX)) {
        send(res, 404, { ok: false, error: 'not found' })
        return
      }
      const refusal = checkRequest(
        {
          host: header(req, 'host'),
          origin: header(req, 'origin'),
          token: header(req, TOKEN_HEADER),
          contentType: header(req, 'content-type'),
        },
        policy,
      )
      if (refusal !== null) {
        send(res, refusal.status, { ok: false, error: refusal.error })
        return
      }
      const text = await readBody(req)
      let params: unknown
      try {
        params = text === '' ? {} : JSON.parse(text)
      } catch {
        throw new CallError('the body is not valid JSON', 400)
      }
      const result = await handleCall(url.slice(API_PREFIX.length), params, context)
      send(res, 200, { ok: true, result })
    } catch (error) {
      if (error instanceof CallError) {
        send(res, error.status, { ok: false, error: error.message })
      } else {
        console.error(error)
        send(res, 500, { ok: false, error: 'internal error' })
      }
    }
  }
}
