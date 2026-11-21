import { EventEmitter } from 'node:events'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { WebSocket } from 'ws'
import { attachGatewayFlow } from './gateway-flow-control.ts'
import { attachGatewayHeartbeat } from './gateway-heartbeat.ts'

class FakeSocket extends EventEmitter {
  readonly readyState = WebSocket.OPEN
  bufferedAmount = 0
  isPaused = false
  sent = 0
  pings = 0

  send(data: Buffer, _options: { binary: boolean }, done: (error?: Error) => void): void {
    this.sent += 1
    this.bufferedAmount += data.length
    done()
  }

  pause(): void {
    this.isPaused = true
  }

  resume(): void {
    this.isPaused = false
  }

  ping(): void {
    this.pings += 1
  }

  asWebSocket(): WebSocket {
    return this as unknown as WebSocket
  }
}

afterEach(() => {
  vi.useRealTimers()
})

describe('private gateway WebSocket flow control', () => {
  const limits = {
    highWaterBytes: 100,
    lowWaterBytes: 30,
    maxBufferedBytes: 300,
    timeoutMs: 100,
    pollMs: 10,
  }

  it('pauses the sending peer and resumes when destination buffering drains', () => {
    vi.useFakeTimers()
    const client = new FakeSocket()
    const upstream = new FakeSocket()
    const fail = vi.fn()
    const stop = attachGatewayFlow(client.asWebSocket(), upstream.asWebSocket(), fail, limits)

    client.emit('message', Buffer.alloc(120), false)
    expect(upstream.sent).toBe(1)
    expect(client.isPaused).toBe(true)
    upstream.bufferedAmount = 20
    vi.advanceTimersByTime(10)
    expect(client.isPaused).toBe(false)
    expect(fail).not.toHaveBeenCalled()

    upstream.emit('message', Buffer.alloc(120), false)
    expect(upstream.isPaused).toBe(true)
    client.bufferedAmount = 20
    vi.advanceTimersByTime(10)
    expect(upstream.isPaused).toBe(false)
    stop()
  })

  it('rejects a frame when the receiving buffer would exceed the hard cap', () => {
    vi.useFakeTimers()
    const client = new FakeSocket()
    const upstream = new FakeSocket()
    upstream.bufferedAmount = 280
    const fail = vi.fn()
    const stop = attachGatewayFlow(client.asWebSocket(), upstream.asWebSocket(), fail, limits)
    client.emit('message', Buffer.alloc(30), false)
    expect(fail).toHaveBeenCalledOnce()
    expect(upstream.sent).toBe(0)
    stop()
  })

  it('terminates a peer blocked beyond the backpressure deadline', () => {
    vi.useFakeTimers()
    const client = new FakeSocket()
    const upstream = new FakeSocket()
    const fail = vi.fn()
    const stop = attachGatewayFlow(client.asWebSocket(), upstream.asWebSocket(), fail, limits)
    client.emit('message', Buffer.alloc(120), false)
    expect(client.isPaused).toBe(true)
    vi.advanceTimersByTime(120)
    expect(fail).toHaveBeenCalled()
    stop()
  })

  it('refuses invalid thresholds', () => {
    expect(() =>
      attachGatewayFlow(new FakeSocket().asWebSocket(), new FakeSocket().asWebSocket(), vi.fn(), {
        ...limits,
        lowWaterBytes: 120,
      }),
    ).toThrow()
  })
})

describe('private gateway WebSocket heartbeats', () => {
  it('closes when either peer misses the next pong deadline', () => {
    vi.useFakeTimers()
    const client = new FakeSocket()
    const upstream = new FakeSocket()
    const fail = vi.fn()
    const stop = attachGatewayHeartbeat(client.asWebSocket(), upstream.asWebSocket(), fail, 100)
    vi.advanceTimersByTime(100)
    expect(client.pings).toBe(1)
    expect(upstream.pings).toBe(1)
    client.emit('pong')
    vi.advanceTimersByTime(100)
    expect(fail).toHaveBeenCalledOnce()
    stop()
  })

  it('keeps both peers alive when both answer, and cleans up on stop', () => {
    vi.useFakeTimers()
    const client = new FakeSocket()
    const upstream = new FakeSocket()
    const fail = vi.fn()
    const stop = attachGatewayHeartbeat(client.asWebSocket(), upstream.asWebSocket(), fail, 100)
    vi.advanceTimersByTime(100)
    client.emit('pong')
    upstream.emit('pong')
    vi.advanceTimersByTime(100)
    expect(fail).not.toHaveBeenCalled()
    stop()
    vi.advanceTimersByTime(500)
    expect(client.pings).toBe(2)
    expect(fail).not.toHaveBeenCalled()
  })
})
