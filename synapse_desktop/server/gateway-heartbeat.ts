// Ping both ends of an authenticated WebSocket tunnel and terminate the
// connection when either peer fails to answer before the next heartbeat.
import type { WebSocket } from 'ws'

export function attachGatewayHeartbeat(
  client: WebSocket,
  upstream: WebSocket,
  onTimeout: () => void,
  heartbeatMs = 30_000,
): () => void {
  if (!Number.isSafeInteger(heartbeatMs) || heartbeatMs < 1) {
    throw new Error('invalid gateway heartbeat interval')
  }
  let clientAlive = true
  let upstreamAlive = true
  const clientPong = () => {
    clientAlive = true
  }
  const upstreamPong = () => {
    upstreamAlive = true
  }
  client.on('pong', clientPong)
  upstream.on('pong', upstreamPong)
  const timer = setInterval(() => {
    if (!clientAlive || !upstreamAlive) {
      onTimeout()
      return
    }
    clientAlive = false
    upstreamAlive = false
    client.ping()
    upstream.ping()
  }, heartbeatMs)
  timer.unref()
  return () => {
    clearInterval(timer)
    client.off('pong', clientPong)
    upstream.off('pong', upstreamPong)
  }
}
