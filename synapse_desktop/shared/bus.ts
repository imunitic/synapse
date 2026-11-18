// What the frontend does with a Link: it asks and is answered by the id of the question, it
// subscribes to a topic and is told what happens there, and it opens streams. When a Link closes
// and another is given, the subscriptions are made again from the last event each had.

import type { ClientLink } from './link.ts'
import { isMessageName, messages, type MessageName, type Params, type Result } from './messages.ts'
import {
  hostMessageSchema,
  type Capabilities,
  type Cursor,
  type ErrorCode,
  type StreamData,
  type Topic,
} from './protocol.ts'

// A host's refusal or failure, with the code it gave.
export class BusError extends Error {
  readonly code: ErrorCode

  constructor(code: ErrorCode, message: string) {
    super(message)
    this.code = code
  }
}

type EventHandler = (data: unknown, cursor: Cursor | undefined) => void

interface Pending {
  name: MessageName
  resolve: (result: never) => void
  reject: (error: Error) => void
}

interface Subscription {
  handlers: Set<EventHandler>
  // The last event this client has, which a new Link resumes from.
  cursor: Cursor | undefined
}

export class Bus {
  private link: ClientLink | null = null
  private detach: (() => void)[] = []
  private nextId = 1
  private readonly pending = new Map<string, Pending>()
  private readonly subscriptions = new Map<Topic, Subscription>()
  private readonly streams = new Map<string, Set<(data: StreamData) => void>>()
  private readonly hellos = new Set<(capabilities: Capabilities) => void>()
  private readonly closers = new Set<() => void>()
  private known: Capabilities | null = null

  constructor(link?: ClientLink) {
    if (link !== undefined) this.attach(link)
  }

  // Uses another Link, after the one before it closed or in its place, and subscribes again to what
  // was subscribed to, after the last event of each.
  attach(link: ClientLink): void {
    this.leave()
    this.link = link
    this.known = null
    this.detach = [
      link.onMessage((message) => this.receive(message)),
      link.onClose(() => {
        if (this.link !== link) return
        this.leave()
        this.failAll(new BusError('unavailable', 'the connection closed'))
        for (const closer of [...this.closers]) closer()
      }),
    ]
    for (const [topic, subscription] of this.subscriptions) {
      link.send({
        kind: 'subscribe',
        topic,
        ...(subscription.cursor === undefined ? {} : { after: subscription.cursor }),
      })
    }
  }

  // What the host said it can do, once it has said so.
  get capabilities(): Capabilities | null {
    return this.known
  }

  onHello(handler: (capabilities: Capabilities) => void): () => void {
    this.hellos.add(handler)
    if (this.known !== null) handler(this.known)
    return () => this.hellos.delete(handler)
  }

  onClose(handler: () => void): () => void {
    this.closers.add(handler)
    return () => this.closers.delete(handler)
  }

  request<N extends MessageName>(name: N, params: Params<N>): Promise<Result<N>> {
    const link = this.link
    if (link === null) {
      return Promise.reject(new BusError('unavailable', 'there is no connection'))
    }
    const id = `r${this.nextId++}`
    return new Promise<Result<N>>((resolve, reject) => {
      this.pending.set(id, {
        name,
        resolve: resolve as (result: never) => void,
        reject,
      })
      link.send({ kind: 'request', id, name, params })
    })
  }

  subscribe(topic: Topic, handler: EventHandler, after?: Cursor): () => void {
    let subscription = this.subscriptions.get(topic)
    const first = subscription === undefined
    if (subscription === undefined) {
      subscription = { handlers: new Set(), cursor: after }
      this.subscriptions.set(topic, subscription)
    }
    subscription.handlers.add(handler)
    if (first) {
      this.link?.send({ kind: 'subscribe', topic, ...(after === undefined ? {} : { after }) })
    }
    return () => {
      const held = this.subscriptions.get(topic)
      if (held === undefined) return
      held.handlers.delete(handler)
      if (held.handlers.size === 0) {
        this.subscriptions.delete(topic)
        this.link?.send({ kind: 'unsubscribe', topic })
      }
    }
  }

  stream(session: string, data: StreamData): void {
    this.link?.send({ kind: 'stream', session, data })
  }

  onStream(session: string, handler: (data: StreamData) => void): () => void {
    let handlers = this.streams.get(session)
    if (handlers === undefined) {
      handlers = new Set()
      this.streams.set(session, handlers)
    }
    handlers.add(handler)
    return () => this.streams.get(session)?.delete(handler)
  }

  close(): void {
    this.link?.close()
  }

  private leave(): void {
    for (const stop of this.detach) stop()
    this.detach = []
    this.link = null
  }

  private failAll(error: Error): void {
    const waiting = [...this.pending.values()]
    this.pending.clear()
    for (const request of waiting) request.reject(error)
  }

  private receive(raw: unknown): void {
    const parsed = hostMessageSchema.safeParse(raw)
    if (!parsed.success) return
    const message = parsed.data
    switch (message.kind) {
      case 'hello':
        this.known = message.capabilities
        for (const handler of [...this.hellos]) handler(message.capabilities)
        return
      case 'reply': {
        const request = this.pending.get(message.id)
        if (request === undefined) return
        this.pending.delete(message.id)
        if (message.error !== undefined) {
          request.reject(new BusError(message.error.code, message.error.message))
          return
        }
        if (!isMessageName(request.name)) return
        const checked = messages[request.name].result.safeParse(message.result)
        if (checked.success) request.resolve(checked.data as never)
        else {
          request.reject(
            new BusError('internal', `the answer to ${request.name} is not what it should be`),
          )
        }
        return
      }
      case 'event': {
        const subscription = this.subscriptions.get(message.topic)
        if (subscription === undefined) return
        if (message.cursor !== undefined) {
          subscription.cursor = Math.max(subscription.cursor ?? -1, message.cursor)
        }
        for (const handler of [...subscription.handlers]) handler(message.data, message.cursor)
        return
      }
      case 'stream':
        for (const handler of [...(this.streams.get(message.session) ?? [])]) handler(message.data)
    }
  }
}
