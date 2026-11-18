// The frontend's end of a Link over Tauri's IPC to the host in the app's own process: `bus_connect`
// opens a connection and gives it a channel for what the host says, and `bus_send` sends it
// messages. What is sent before the connection is open waits for it, in order.

import { Channel, invoke } from '@tauri-apps/api/core'
import { Bus } from '../../shared/bus.ts'
import type { ClientLink } from '../../shared/link.ts'
import type { ClientMessage, HostMessage } from '../../shared/protocol.ts'

// Whether the page runs in the desktop app's window.
export function inTauri(): boolean {
  return '__TAURI_INTERNALS__' in window
}

// What the adapter itself adds to the host's messages: the host's end of the connection is gone.
interface Closed {
  kind: 'close'
}

export function tauriLink(): ClientLink {
  const handlers = new Set<(message: HostMessage) => void>()
  const closers = new Set<() => void>()
  let closed = false
  const channel = new Channel<HostMessage | Closed>()
  const finish = (): void => {
    if (closed) return
    closed = true
    for (const closer of [...closers]) closer()
  }
  channel.onmessage = (message) => {
    if (message.kind === 'close') finish()
    else for (const handler of [...handlers]) handler(message)
  }
  const connection = invoke<number>('bus_connect', { onMessage: channel })
  // One message after another: each waits for the one before it, so that they arrive in the order
  // they were sent.
  let queue: Promise<unknown> = connection.catch(() => undefined)
  connection.catch(finish)
  return {
    send(message: ClientMessage) {
      if (closed) return
      queue = queue.then(async () => {
        try {
          await invoke('bus_send', { connection: await connection, message })
        } catch {
          finish()
        }
      })
    },
    onMessage(handler) {
      handlers.add(handler)
      return () => handlers.delete(handler)
    },
    onClose(handler) {
      closers.add(handler)
      return () => closers.delete(handler)
    },
    close() {
      void connection.then((id) => invoke('bus_close', { connection: id })).catch(() => undefined)
      finish()
    },
  }
}

// A bus to the host of the app, made again if the connection is lost.
export function connectTauriBus(): Bus {
  const bus = new Bus(tauriLink())
  bus.onClose(() => {
    setTimeout(() => bus.attach(tauriLink()), 1000)
  })
  return bus
}
