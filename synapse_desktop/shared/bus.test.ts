import { describe, expect, it } from 'vitest'
import { Bus, BusError } from './bus.ts'
import { HostError, serve, type Connection, type Handlers } from './dispatch.ts'
import { linkPair } from './link.ts'
import type { Capabilities } from './protocol.ts'

const capabilities: Capabilities = {
  host: 'fake',
  shell: true,
  installActions: false,
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0))

function connect(handlers: Handlers, replay?: Parameters<typeof serve>[1]['replay']) {
  const { client, host } = linkPair()
  const connection = serve(host, { handlers, capabilities, replay })
  return { bus: new Bus(client), connection, client, host }
}

const readHandlers: Handlers = {
  'fs.read': ({ path }) => {
    if (path === '/missing') throw new HostError('not_found', 'no such file')
    if (path === '/boom') throw new Error('secret detail')
    return { text: `text of ${path}` }
  },
  'run.stop': () => undefined as never,
}

describe('a bus and a host', () => {
  it('answers a request with its result, matched by id when two are in flight', async () => {
    const { bus } = connect(readHandlers)
    const [a, b] = await Promise.all([
      bus.request('fs.read', { path: '/a' }),
      bus.request('fs.read', { path: '/b' }),
    ])
    expect(a.text).toBe('text of /a')
    expect(b.text).toBe('text of /b')
  })

  it('carries a refusal with its code, and hides what an unexpected failure says', async () => {
    const { bus } = connect(readHandlers)
    await expect(bus.request('fs.read', { path: '/missing' })).rejects.toMatchObject({
      code: 'not_found',
      message: 'no such file',
    })
    const failure = await bus.request('fs.read', { path: '/boom' }).catch((e: unknown) => e)
    expect(failure).toBeInstanceOf(BusError)
    expect((failure as BusError).code).toBe('internal')
    expect((failure as BusError).message).not.toContain('secret')
  })

  it("refuses parameters that are not the message's, before the handler sees them", async () => {
    let called = false
    const { bus } = connect({
      'fs.read': () => {
        called = true
        return { text: '' }
      },
    })
    await expect(
      bus.request('fs.read', { path: 42 } as unknown as { path: string }),
    ).rejects.toMatchObject({ code: 'bad_request' })
    expect(called).toBe(false)
  })

  it('answers a message the host has no handler for as unavailable, and a null result as null', async () => {
    const { bus } = connect(readHandlers)
    await expect(bus.request('diagnose', {})).rejects.toMatchObject({ code: 'unavailable' })
    await expect(bus.request('run.stop', { executionId: 'exec-1' })).resolves.toBeNull()
  })

  it('refuses an answer that is not what the message says it is', async () => {
    const { bus } = connect({ 'fs.read': () => ({ text: 5 }) as never })
    await expect(bus.request('fs.read', { path: '/a' })).rejects.toMatchObject({ code: 'internal' })
  })

  it('tells the client what the host can do, also to one that asks late', async () => {
    const { bus } = connect(readHandlers)
    await tick()
    expect(bus.capabilities).toEqual(capabilities)
    let seen: Capabilities | null = null
    bus.onHello((c) => (seen = c))
    expect(seen).toEqual(capabilities)
  })

  it('delivers events of a topic only to a client subscribed to it', async () => {
    const { bus, connection } = connect(readHandlers)
    const seen: unknown[] = []
    bus.subscribe('files.vault', (data) => seen.push(data))
    await tick()
    connection.publish('files.vault', { path: 'a.md' })
    connection.publish('files.work', { path: 'ignored' })
    await tick()
    expect(seen).toEqual([{ path: 'a.md' }])
  })

  it('stops delivering after the last handler unsubscribes', async () => {
    const { bus, connection } = connect(readHandlers)
    const seen: unknown[] = []
    const stop = bus.subscribe('files.vault', (data) => seen.push(data))
    await tick()
    stop()
    await tick()
    expect(connection.watching('files.vault')).toBe(false)
    connection.publish('files.vault', 1)
    await tick()
    expect(seen).toEqual([])
  })

  it('resumes a subscription after the last event it has when a new link is attached', async () => {
    const log = [
      { cursor: 0, data: 'zero' },
      { cursor: 1, data: 'one' },
      { cursor: 2, data: 'two' },
    ]
    const replay = (_topic: string, after: number) => log.filter((e) => e.cursor > after)
    const first = connect(readHandlers, replay)
    const seen: unknown[] = []
    first.bus.subscribe('run.exec-1', (data) => seen.push(data))
    await tick()
    first.connection.publish('run.exec-1', 'one', 1)
    await tick()
    expect(seen).toEqual(['one'])

    // The link breaks; a new one is made and the same bus is given it.
    first.client.close()
    const second = linkPair()
    serve(second.host, { handlers: readHandlers, capabilities, replay })
    first.bus.attach(second.client)
    await tick()
    expect(seen).toEqual(['one', 'two'])
  })

  it('fails what was in flight when the link closes, and says so to a listener', async () => {
    const { client, host } = linkPair()
    const bus = new Bus(client)
    let closed = 0
    bus.onClose(() => closed++)
    const pending = bus.request('fs.read', { path: '/a' })
    host.close()
    await expect(pending).rejects.toMatchObject({ code: 'unavailable' })
    expect(closed).toBe(1)
    await expect(bus.request('fs.read', { path: '/a' })).rejects.toMatchObject({
      code: 'unavailable',
    })
  })

  it('carries the messages of a stream both ways', async () => {
    const received: unknown[] = []
    const { client, host } = linkPair()
    const connection: Connection = serve(host, {
      handlers: {},
      capabilities,
      onStream: (session, data) => received.push([session, data]),
    })
    const bus = new Bus(client)
    const output: unknown[] = []
    bus.onStream('t1', (data) => output.push(data))
    bus.stream('t1', { type: 'input', data: 'ls' })
    connection.stream('t1', { type: 'output', data: 'a b' })
    await tick()
    expect(received).toEqual([['t1', { type: 'input', data: 'ls' }]])
    expect(output).toEqual([{ type: 'output', data: 'a b' }])
  })

  it('ignores what is not a message, from either end', async () => {
    const { client, host } = linkPair()
    serve(host, { handlers: readHandlers, capabilities })
    const bus = new Bus(client)
    ;(client as unknown as { send(m: unknown): void }).send({ kind: 'nonsense' })
    ;(host as unknown as { send(m: unknown): void }).send({ kind: 'nonsense' })
    await tick()
    await expect(bus.request('fs.read', { path: '/a' })).resolves.toEqual({ text: 'text of /a' })
  })
})

describe('what a host starts for a subscription', () => {
  it('starts it for the first subscription to a topic, hands it the cursor, and ends it with the last', async () => {
    const started: { topic: string; after: number | undefined }[] = []
    let ended = 0
    const { client, host } = linkPair()
    serve(host, {
      handlers: {},
      capabilities,
      subscribe: (topic, after, push) => {
        started.push({ topic, after })
        push('first', 7)
        return () => {
          ended++
        }
      },
    })
    const bus = new Bus(client)
    const seen: unknown[] = []
    const stopOne = bus.subscribe('run.exec-1', (data, cursor) => seen.push([data, cursor]), 3)
    const stopTwo = bus.subscribe('run.exec-1', () => undefined)
    await tick()
    expect(started).toEqual([{ topic: 'run.exec-1', after: 3 }])
    expect(seen).toEqual([['first', 7]])
    stopOne()
    await tick()
    expect(ended).toBe(0)
    stopTwo()
    await tick()
    expect(ended).toBe(1)
  })

  it('ends what it started when the connection closes', async () => {
    let ended = 0
    const { client, host } = linkPair()
    serve(host, {
      handlers: {},
      capabilities,
      subscribe: () => async () => {
        ended++
      },
    })
    const bus = new Bus(client)
    bus.subscribe('files.work', () => undefined)
    await tick()
    client.close()
    await tick()
    await tick()
    expect(ended).toBe(1)
  })
})
