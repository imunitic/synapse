// The frontend's end of a Link over a WebSocket to the host's bus, which the dev server proxies to
// the host with the token added. What is sent before the socket has opened waits for it.

import { BUS_PATH } from '../../shared/constants.ts'
import { Bus } from '../../shared/bus.ts'
import type { ClientLink } from '../../shared/link.ts'

export function socketLink(url: string): ClientLink {
  const socket = new WebSocket(url)
  const waiting: string[] = []
  socket.addEventListener('open', () => {
    for (const text of waiting.splice(0)) socket.send(text)
  })
  return {
    send(message) {
      const text = JSON.stringify(message)
      if (socket.readyState === WebSocket.OPEN) socket.send(text)
      else if (socket.readyState === WebSocket.CONNECTING) waiting.push(text)
    },
    onMessage(handler) {
      const listener = (event: MessageEvent<unknown>) => {
        if (typeof event.data !== 'string') return
        try {
          handler(JSON.parse(event.data) as never)
        } catch {
          // Not JSON: not a message.
        }
      }
      socket.addEventListener('message', listener)
      return () => socket.removeEventListener('message', listener)
    },
    onClose(handler) {
      socket.addEventListener('close', handler)
      return () => socket.removeEventListener('close', handler)
    },
    close() {
      socket.close()
    },
  }
}

const RECONNECT_MS = 1000

// A bus on the page's own host, made again after the connection is lost.
export function connectBus(): Bus {
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
  const url = `${scheme}://${location.host}${BUS_PATH}`
  const bus = new Bus(socketLink(url))
  bus.onClose(() => {
    setTimeout(() => bus.attach(socketLink(url)), RECONNECT_MS)
  })
  return bus
}
