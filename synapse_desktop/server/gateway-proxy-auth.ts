import { createHash, timingSafeEqual } from 'node:crypto'
import { createServer, type IncomingMessage, type Server } from 'node:http'

const header = 'x-synapse-proxy-token'
const digest = (value: string) => createHash('sha256').update(value).digest()

export function createAuthenticatedProxyServer(dispatcher: Server, token: string): Server {
  if (!/^[0-9a-f]{64}$/.test(token)) throw new Error('invalid proxy token')
  const expected = digest(token)
  const authorized = (request: IncomingMessage): boolean => {
    let count = 0
    for (let i = 0; i < request.rawHeaders.length; i += 2) {
      if (request.rawHeaders[i]?.toLowerCase() === header) count++
    }
    const supplied = request.headers[header]
    const valid =
      count === 1 &&
      typeof supplied === 'string' &&
      /^[0-9a-f]{64}$/.test(supplied) &&
      timingSafeEqual(digest(supplied), expected)
    delete request.headers[header]
    for (let i = request.rawHeaders.length - 2; i >= 0; i -= 2) {
      if (request.rawHeaders[i]?.toLowerCase() === header) request.rawHeaders.splice(i, 2)
    }
    return valid
  }
  const server = createServer((request, response) => {
    if (!authorized(request)) {
      response.writeHead(403, { Connection: 'close', 'Content-Length': '0' }).end()
      return
    }
    dispatcher.emit('request', request, response)
  })
  server.on('upgrade', (request, socket, head) => {
    if (!authorized(request)) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
      return
    }
    dispatcher.emit('upgrade', request, socket, head)
  })
  return server
}
