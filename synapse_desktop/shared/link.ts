// A Link is a pipe that sends one kind of message and delivers the other: a WebSocket for the
// browser build and a server, Tauri's IPC for the desktop build, and a pair of functions in a test
// or when the frontend is tried against a fake host. The two ends of a Link are of two types: the
// client sends what the host receives, and the other way round.

import type { ClientMessage, HostMessage } from './protocol.ts'

export type Unsubscribe = () => void

export interface Link<Out, In> {
  // Sends a message. A message sent after the Link has closed is lost.
  send(message: Out): void
  onMessage(handler: (message: In) => void): Unsubscribe
  // Called once, when the Link closes, whichever end closed it.
  onClose(handler: () => void): Unsubscribe
  close(): void
}

// What the frontend holds, and what a host holds of one connection.
export type ClientLink = Link<ClientMessage, HostMessage>
export type HostLink = Link<HostMessage, ClientMessage>

// What goes over a real Link is JSON, so what does not survive it (a value that is `undefined`, a
// date) does not survive a Link in a test either.
function wire<T>(message: T): T {
  return JSON.parse(JSON.stringify(message)) as T
}

class Endpoint<Out, In> implements Link<Out, In> {
  private readonly handlers = new Set<(message: In) => void>()
  private readonly closers = new Set<() => void>()
  private closed = false
  other: Endpoint<In, Out> | null = null

  send(message: Out): void {
    const other = this.other
    if (this.closed || other === null || other.closed) return
    const delivered = wire(message)
    // Delivery is asynchronous, as it is over a real connection.
    queueMicrotask(() => {
      if (other.closed) return
      for (const handler of [...other.handlers]) handler(delivered)
    })
  }

  onMessage(handler: (message: In) => void): Unsubscribe {
    this.handlers.add(handler)
    return () => this.handlers.delete(handler)
  }

  onClose(handler: () => void): Unsubscribe {
    this.closers.add(handler)
    return () => this.closers.delete(handler)
  }

  close(): void {
    this.end()
    this.other?.end()
  }

  private end(): void {
    if (this.closed) return
    this.closed = true
    for (const closer of [...this.closers]) closer()
  }
}

// The two ends of one connection. Closing either closes both.
export function linkPair(): { client: ClientLink; host: HostLink } {
  const client = new Endpoint<ClientMessage, HostMessage>()
  const host = new Endpoint<HostMessage, ClientMessage>()
  client.other = host
  host.other = client
  return { client, host }
}
