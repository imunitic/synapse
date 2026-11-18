// What a host does with one connection: it says what it can do, answers each request by calling the
// handler of the message, and tells the clients subscribed to a topic what happens there. The Node
// host and the fake host are both this, with their own handlers.

import type { HostLink } from './link.ts'
import { isMessageName, messages, type MessageName, type Params, type Result } from './messages.ts'
import {
  clientMessageSchema,
  PROTOCOL_VERSION,
  type Capabilities,
  type Cursor,
  type ErrorCode,
  type StreamData,
  type Topic,
} from './protocol.ts'

// A refusal with a code, which a handler throws.
export class HostError extends Error {
  readonly code: ErrorCode

  constructor(code: ErrorCode, message: string) {
    super(message)
    this.code = code
  }
}

export type Handler<N extends MessageName> = (params: Params<N>) => Promise<Result<N>> | Result<N>

export type Handlers = { [N in MessageName]?: Handler<N> }

export interface ServeOptions {
  handlers: Handlers
  capabilities: Capabilities
  // The events of a topic after a cursor, for a client that subscribes from one.
  replay?: (topic: Topic, after: Cursor) => { cursor: Cursor; data: unknown }[]
  // Whether a client may subscribe to a topic; every topic when absent.
  mayWatch?: (topic: Topic) => boolean
  // What a subscription to a topic starts, which `push` gives its events and the returned function
  // ends. It is called for the first subscription of a connection to a topic, with the cursor of
  // the last event the client has, and ended when the client unsubscribes or the connection closes.
  subscribe?: (
    topic: Topic,
    after: Cursor | undefined,
    push: (data: unknown, cursor?: Cursor) => void,
  ) => (() => void) | Promise<() => void>
  // A message of a stream, from the client.
  onStream?: (session: string, data: StreamData) => void
  // What a failure that is not a refusal comes to; the client is told it was internal.
  report?: (error: unknown) => void
}

export interface Connection {
  // Tells the clients subscribed to the topic. An event of a topic that has a cursor goes with it.
  publish(topic: Topic, data: unknown, cursor?: Cursor): void
  stream(session: string, data: StreamData): void
  // Whether some client of this connection is subscribed to the topic.
  watching(topic: Topic): boolean
  close(): void
}

export function serve(link: HostLink, options: ServeOptions): Connection {
  const subscribed = new Set<Topic>()
  // What each subscription started, to be ended with it.
  const running = new Map<Topic, Promise<() => void>>()

  const end = (topic: Topic) => {
    const started = running.get(topic)
    running.delete(topic)
    void started?.then((stop) => stop())
  }

  const failure = (id: string, code: ErrorCode, message: string) =>
    link.send({ kind: 'reply', id, error: { code, message } })

  async function answer(id: string, name: string, params: unknown): Promise<void> {
    if (!isMessageName(name)) {
      failure(id, 'not_found', `there is no message ${name}`)
      return
    }
    const checked = messages[name].params.safeParse(params ?? undefined)
    if (!checked.success) {
      failure(id, 'bad_request', `invalid parameters: ${checked.error.message}`)
      return
    }
    const handler = options.handlers[name] as ((p: unknown) => unknown) | undefined
    if (handler === undefined) {
      failure(id, 'unavailable', `this host does not answer ${name}`)
      return
    }
    try {
      const result = await handler(checked.data)
      link.send({ kind: 'reply', id, result: result === undefined ? null : result })
    } catch (error) {
      if (error instanceof HostError) {
        failure(id, error.code, error.message)
      } else {
        options.report?.(error)
        failure(id, 'internal', 'internal error')
      }
    }
  }

  link.onMessage((raw) => {
    const parsed = clientMessageSchema.safeParse(raw)
    if (!parsed.success) return
    const message = parsed.data
    switch (message.kind) {
      case 'request':
        void answer(message.id, message.name, message.params)
        return
      case 'subscribe': {
        if (options.mayWatch?.(message.topic) === false) return
        const known = subscribed.has(message.topic)
        subscribed.add(message.topic)
        if (!known && options.subscribe !== undefined) {
          const topic = message.topic
          running.set(
            topic,
            Promise.resolve(
              options.subscribe(topic, message.after, (data, cursor) =>
                link.send({
                  kind: 'event',
                  topic,
                  ...(cursor === undefined ? {} : { cursor }),
                  data,
                }),
              ),
            ),
          )
        }
        if (message.after !== undefined) {
          for (const event of options.replay?.(message.topic, message.after) ?? []) {
            link.send({
              kind: 'event',
              topic: message.topic,
              cursor: event.cursor,
              data: event.data,
            })
          }
        }
        return
      }
      case 'unsubscribe':
        subscribed.delete(message.topic)
        end(message.topic)
        return
      case 'stream':
        options.onStream?.(message.session, message.data)
    }
  })

  link.onClose(() => {
    for (const topic of [...running.keys()]) end(topic)
    subscribed.clear()
  })

  link.send({ kind: 'hello', protocol: PROTOCOL_VERSION, capabilities: options.capabilities })

  return {
    publish(topic, data, cursor) {
      if (!subscribed.has(topic)) return
      link.send({ kind: 'event', topic, ...(cursor === undefined ? {} : { cursor }), data })
    },
    stream(session, data) {
      link.send({ kind: 'stream', session, data })
    },
    watching: (topic) => subscribed.has(topic),
    close: () => link.close(),
  }
}
