import { createServer, request } from 'node:http'
import { connect } from 'node:net'
import { describe, expect, it } from 'vitest'
import { createAuthenticatedProxyServer } from './gateway-proxy-auth.ts'

const token = 'a'.repeat(64)

describe('authenticated proxy ingress', () => {
  it('rejects invalid configuration', () => {
    expect(() => createAuthenticatedProxyServer(createServer(), 'short')).toThrow()
  })

  it('authenticates HTTP and upgrades before dispatch and strips the credential', async () => {
    const dispatcher = createServer()
    let dispatched = 0
    dispatcher.on('request', (req, res) => {
      dispatched++
      expect(req.headers['x-synapse-proxy-token']).toBeUndefined()
      expect(req.rawHeaders.map((part) => part.toLowerCase())).not.toContain('x-synapse-proxy-token')
      res.writeHead(204).end()
    })
    dispatcher.on('upgrade', (req, socket) => {
      dispatched++
      expect(req.headers['x-synapse-proxy-token']).toBeUndefined()
      socket.end(
        'HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n',
      )
    })
    const server = createAuthenticatedProxyServer(dispatcher, token)
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('missing test port')
    const port = address.port
    const http = (headers: Record<string, string | string[]> = {}) =>
      new Promise<number>((resolve, reject) => {
        const req = request({ host: '127.0.0.1', port, headers }, (res) => {
          res.resume()
          resolve(res.statusCode ?? 0)
        })
        req.on('error', reject)
        req.end()
      })
    const upgrade = (credential?: string) =>
      new Promise<string>((resolve, reject) => {
        const socket = connect(port, '127.0.0.1', () => {
          socket.end(
            'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n' +
              (credential ? `X-Synapse-Proxy-Token: ${credential}\r\n` : '') +
              '\r\n',
          )
        })
        let result = ''
        socket.setEncoding('utf8')
        socket.on('data', (chunk) => (result += chunk))
        socket.on('end', () => resolve(result))
        socket.on('error', reject)
      })
    try {
      expect(await http({ 'x-forwarded-for': '192.0.2.1' })).toBe(403)
      expect(await http({ 'x-synapse-proxy-token': 'b'.repeat(64) })).toBe(403)
      expect(await http({ 'x-synapse-proxy-token': [token, token] })).toBe(403)
      expect(await upgrade()).toContain('403 Forbidden')
      expect(dispatched).toBe(0)
      expect(await http({ 'x-synapse-proxy-token': token })).toBe(204)
      expect(await upgrade(token)).toContain('101 Switching Protocols')
      expect(dispatched).toBe(2)
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      )
    }
  })
})
