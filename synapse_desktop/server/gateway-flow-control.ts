// Bounded bidirectional WebSocket forwarding for the private PWA gateway.
// The same controller is used by live connections and deterministic unit tests.
import { WebSocket } from 'ws'

export interface GatewayFlowOptions {
  readonly highWaterBytes?: number
  readonly lowWaterBytes?: number
  readonly maxBufferedBytes?: number
  readonly timeoutMs?: number
  readonly pollMs?: number
  readonly now?: () => number
}

export function attachGatewayFlow(
  client: WebSocket,
  upstream: WebSocket,
  fail: () => void,
  options: GatewayFlowOptions = {},
): () => void {
  const high = options.highWaterBytes ?? 1024 * 1024
  const low = options.lowWaterBytes ?? 512 * 1024
  const maximum = options.maxBufferedBytes ?? 8 * 1024 * 1024
  const timeout = options.timeoutMs ?? 20_000
  const poll = options.pollMs ?? 100
  const now = options.now ?? Date.now
  if (
    !Number.isSafeInteger(high) ||
    !Number.isSafeInteger(low) ||
    !Number.isSafeInteger(maximum) ||
    !Number.isSafeInteger(timeout) ||
    !Number.isSafeInteger(poll) ||
    low < 0 ||
    low >= high ||
    high >= maximum ||
    timeout <= 0 ||
    poll <= 0
  ) {
    throw new Error('invalid gateway WebSocket flow limits')
  }

  let clientPausedAt: number | null = null
  let upstreamPausedAt: number | null = null
  let stopped = false

  const relay = (
    source: WebSocket,
    destination: WebSocket,
    data: Buffer | ArrayBuffer | Buffer[],
    binary: boolean,
  ) => {
    if (stopped) return
    if (binary || destination.readyState !== WebSocket.OPEN) {
      fail()
      return
    }
    const size = Array.isArray(data)
      ? data.reduce((total, chunk) => total + chunk.length, 0)
      : data.byteLength
    if (destination.bufferedAmount + size > maximum) {
      fail()
      return
    }
    destination.send(data, { binary: false }, (error) => {
      if (error) fail()
    })
    if (destination.bufferedAmount >= high && !source.isPaused) {
      source.pause()
      if (source === client) clientPausedAt = now()
      else upstreamPausedAt = now()
    }
  }

  const fromClient = (data: Buffer | ArrayBuffer | Buffer[], binary: boolean) =>
    relay(client, upstream, data, binary)
  const fromUpstream = (data: Buffer | ArrayBuffer | Buffer[], binary: boolean) =>
    relay(upstream, client, data, binary)
  client.on('message', fromClient)
  upstream.on('message', fromUpstream)
  const timer = setInterval(() => {
    if (stopped) return
    if (client.isPaused) {
      if (upstream.bufferedAmount < low) {
        client.resume()
        clientPausedAt = null
      } else if (clientPausedAt !== null && now() - clientPausedAt > timeout) fail()
    }
    if (upstream.isPaused) {
      if (client.bufferedAmount < low) {
        upstream.resume()
        upstreamPausedAt = null
      } else if (upstreamPausedAt !== null && now() - upstreamPausedAt > timeout) fail()
    }
  }, poll)
  timer.unref()
  return () => {
    if (stopped) return
    stopped = true
    clearInterval(timer)
    client.off('message', fromClient)
    upstream.off('message', fromUpstream)
  }
}
