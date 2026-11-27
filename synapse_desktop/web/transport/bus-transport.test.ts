import { describe, expect, it } from 'vitest'
import { Bus } from '../../shared/bus.ts'
import { HostError, serve, type Handlers } from '../../shared/dispatch.ts'
import { linkPair } from '../../shared/link.ts'
import { examples } from '../../shared/examples.ts'
import { BusTransport } from './bus-transport.ts'

// A host that answers every message with its example, and records what it was asked.
function host() {
  const asked: { name: string; params: unknown }[] = []
  const handlers: Record<string, (p: unknown) => unknown> = {}
  for (const example of examples) {
    handlers[example.name] = (params) => {
      asked.push({ name: example.name, params })
      return example.result
    }
  }
  const { client, host: end } = linkPair()
  serve(end, {
    handlers: handlers as unknown as Handlers,
    capabilities: { host: 'fake', shell: true, installActions: false },
  })
  return { transport: new BusTransport(new Bus(client)), asked }
}

describe('the Transport over a bus', () => {
  it('sends the folder of a run only when it is given', async () => {
    const { transport, asked } = host()
    await transport.startRun('P', null, '/repo')
    await transport.startRun('P', null)
    expect(asked.map((a) => a.params)).toEqual([
      { pipeline: 'P', input: null, folder: '/repo' },
      { pipeline: 'P', input: null },
    ])
    expect(Object.keys(asked[1]?.params as object)).not.toContain('folder')
  })

  it('reads and lists files through fs.read and fs.list', async () => {
    const { transport, asked } = host()
    expect(await transport.readText('/w/a.json')).toBe('{}')
    expect((await transport.readDir('/w'))[0]?.name).toBe('pipelines')
    expect(asked.map((a) => a.name)).toEqual(['fs.read', 'fs.list'])
  })

  it('tells a create from a replace of a definition by the mode it sends', async () => {
    const { transport, asked } = host()
    await transport.writeDefinition({ kind: 'definition', name: 'Develop', text: 'x' })
    await transport.saveDefinition('/defs/Develop.synapse', 'a', 'b')
    expect(asked.map((a) => (a.params as { mode: string }).mode)).toEqual(['create', 'replace'])
  })

  it('asks one agent.run with the kind that says what to write, and unwraps what it answers', async () => {
    const { transport, asked } = host()
    // The example answers a note-edit, so the other two are refused as another message's answer.
    await expect(
      transport.generateDefinition({ kind: 'pipeline', prompt: 'p', definitions: [], skills: [] }),
    ).rejects.toThrow('another message')
    await expect(transport.createNote({ kind: 'note', prompt: 'p' })).rejects.toThrow(
      'another message',
    )
    const edit = await transport.editNote({ path: 'a.md', prompt: 'p' })
    expect(edit).toEqual({ before: 'a', after: 'b', touched: [] })
    expect(asked.map((a) => (a.params as { kind: string }).kind)).toEqual([
      'definition',
      'note',
      'note-edit',
    ])
  })

  it('passes the run id of an agent call on to the message', async () => {
    const { transport, asked } = host()
    await expect(
      transport.generateDefinition({
        kind: 'pipeline',
        prompt: 'p',
        definitions: [],
        skills: [],
        run: 'r1',
      }),
    ).rejects.toThrow('another message')
    await expect(transport.createNote({ kind: 'note', prompt: 'p', run: 'r2' })).rejects.toThrow(
      'another message',
    )
    await transport.editNote({ path: 'a.md', prompt: 'p', run: 'r3' })
    expect(asked.map((a) => (a.params as { run?: string }).run)).toEqual(['r1', 'r2', 'r3'])
  })

  it('stops an agent run with agent.stop and its id', async () => {
    const { transport, asked } = host()
    await transport.stopAgentRun('run_1')
    expect(asked).toEqual([{ name: 'agent.stop', params: { run: 'run_1' } }])
  })

  it('watches a note run as the topic of its id, hands over its lines and stops', async () => {
    const { client, host: end } = linkPair()
    const topics: string[] = []
    let unsubscribed = 0
    serve(end, {
      handlers: {},
      capabilities: { host: 'fake', shell: true, installActions: false },
      subscribe: (topic, _after, push) => {
        topics.push(topic)
        push({ line: 'one' }, 0)
        push({ line: 'two' }, 1)
        return () => {
          unsubscribed++
        }
      },
    })
    const transport = new BusTransport(new Bus(client))
    const lines: string[] = []
    const stop = transport.watchNoteRun('abc_1', (line) => lines.push(line))
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(topics).toEqual(['note-run.abc_1'])
    expect(lines).toEqual(['one', 'two'])
    stop()
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(unsubscribed).toBe(1)
  })

  it('reads the settings and the paths from one message', async () => {
    const { transport, asked } = host()
    expect((await transport.getConfig()).workDir).toBe('/w')
    expect((await transport.getPaths()).recordsDir).toBe('/w/pipelines')
    expect((await transport.setConfig({ workDir: '/w2' })).workDir).toBe('/w')
    expect(asked.map((a) => a.name)).toEqual(['config.get', 'config.get', 'config.set'])
  })

  it('asks models.get to refresh only when told to', async () => {
    const { transport, asked } = host()
    await transport.listModels('Claude')
    await transport.refreshModels('Claude')
    expect(asked.map((a) => (a.params as { refresh?: boolean }).refresh)).toEqual([undefined, true])
  })

  it('sends a plan and an apply of dropping and cleaning as the four combinations they are', async () => {
    const { transport, asked } = host()
    await transport.planGraphDrop('synapse@main')
    await expect(transport.dropGraph('synapse@main')).rejects.toThrow('another message')
    await transport.planGraphClean('synapse@main')
    await expect(transport.cleanGraphs('synapse@main')).rejects.toThrow('another message')
    expect(asked.map((a) => a.params)).toEqual([
      { action: 'plan', what: 'drop', namespace: 'synapse@main' },
      { action: 'apply', what: 'drop', namespace: 'synapse@main' },
      { action: 'plan', what: 'clean', namespace: 'synapse@main' },
      { action: 'apply', what: 'clean', namespace: 'synapse@main' },
    ])
  })

  it('watches a place as the topic of its files', async () => {
    const { client, host: end } = linkPair()
    const topics: string[] = []
    serve(end, {
      handlers: {},
      capabilities: { host: 'fake', shell: true, installActions: false },
      subscribe: (topic, _after, push) => {
        topics.push(topic)
        push({})
        return () => undefined
      },
    })
    const transport = new BusTransport(new Bus(client))
    let changes = 0
    const stop = transport.watch('vault', () => changes++)
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(topics).toEqual(['files.vault'])
    expect(changes).toBe(1)
    stop()
  })

  it('watches usage on its topic and drops an event that does not parse', async () => {
    const { client, host: end } = linkPair()
    const topics: string[] = []
    const event = {
      readings: [
        {
          harness: 'Opencode',
          kind: 'spend',
          windows: [],
          spend: { amount: 1.42, period: 'today' },
          observedAt: '2026-11-25T10:00:00.000Z',
          state: 'ok',
          reason: null,
        },
      ],
    }
    serve(end, {
      handlers: {},
      capabilities: { host: 'fake', shell: true, installActions: false },
      subscribe: (topic, _after, push) => {
        topics.push(topic)
        push({ readings: [{ harness: 'Opencode' }] }, 0)
        push(event, 1)
        return () => undefined
      },
    })
    const transport = new BusTransport(new Bus(client))
    const received: unknown[] = []
    const stop = transport.watchUsage((e) => received.push(e))
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(topics).toEqual(['usage'])
    expect(received).toEqual([event])
    stop()
  })

  describe('a terminal', () => {
    const info = {
      session: 't1',
      title: 'Shell 1',
      kind: 'Shell' as const,
      cwd: '/p',
      loaded: false,
      note: '',
      exited: null,
    }

    function terminalHost() {
      const asked: { name: string; params: unknown }[] = []
      const connect = (bus?: Bus) => {
        const { client, host: end } = linkPair()
        const connection = serve(end, {
          handlers: {
            'terminal.start': (params) => {
              asked.push({ name: 'terminal.start', params })
              return info
            },
            'terminal.attach': (params) => {
              asked.push({ name: 'terminal.attach', params })
              return info
            },
            'terminal.close': (params) => {
              asked.push({ name: 'terminal.close', params })
              return null
            },
          },
          capabilities: { host: 'fake', shell: true, installActions: false },
          onStream: (session, data) => asked.push({ name: `stream ${session}`, params: data }),
        })
        if (bus === undefined) return { bus: new Bus(client), connection, client }
        bus.attach(client)
        return { bus, connection, client }
      }
      return { asked, connect }
    }

    const listener = () => {
      const seen: string[] = []
      return {
        seen,
        listener: {
          onStarted: () => seen.push('started'),
          onOutput: (data: string) => seen.push(`output ${data}`),
          onSnapshot: (data: string) => seen.push(`snapshot ${data}`),
          onRun: () => undefined,
          onExit: (code: number) => seen.push(`exit ${code}`),
          onError: (message: string) => seen.push(`error ${message}`),
          onTranscript: () => undefined,
        },
      }
    }

    const tick = () => new Promise((resolve) => setTimeout(resolve, 10))

    it('is started by the page, gets what the host streams, and sends what is typed', async () => {
      const { asked, connect } = terminalHost()
      const { bus, connection } = connect()
      const { seen, listener: l } = listener()
      const handle = new BusTransport(bus).openTerminal(
        { session: 't1', title: 'Shell 1', kind: 'Shell', cols: 80, rows: 24 },
        l,
      )
      // What is typed before the program has started waits for it.
      handle.write('ls\r')
      await tick()
      connection.stream('t1', { type: 'output', data: 'hi' })
      connection.stream('t1', { type: 'exit', code: 0 })
      await tick()
      expect(seen).toEqual(['started', 'output hi', 'exit 0'])
      expect(asked.map((a) => a.name)).toEqual(['terminal.start', 'stream t1'])
      expect(asked[1]?.params).toEqual({ type: 'input', data: 'ls\r' })
    })

    it('attaches again, at the size it has, when the connection comes back, and shows the screen it is given', async () => {
      const { asked, connect } = terminalHost()
      const first = connect()
      const { seen, listener: l } = listener()
      const handle = new BusTransport(first.bus).openTerminal(
        { session: 't1', title: 'Shell 1', kind: 'Shell', cols: 80, rows: 24 },
        l,
      )
      await tick()
      handle.resize(100, 30)
      first.client.close()
      await tick()
      const second = connect(first.bus)
      await tick()
      await tick()
      expect(asked.filter((a) => a.name.startsWith('terminal'))).toEqual([
        { name: 'terminal.start', params: expect.objectContaining({ session: 't1' }) },
        { name: 'terminal.attach', params: { session: 't1', cols: 100, rows: 30 } },
      ])
      second.connection.stream('t1', { type: 'snapshot', data: 'screen' })
      await tick()
      expect(seen).toContain('snapshot screen')
    })

    it('starts an interactive run with its pipeline, input and name', async () => {
      const { asked, connect } = terminalHost()
      const { bus } = connect()
      const { listener: l } = listener()
      new BusTransport(bus).openTerminal(
        {
          session: 'r1',
          title: 'Develop',
          kind: 'Pipeline',
          pipeline: 'Develop',
          input: 'go',
          runName: 'Fix the login',
          cols: 80,
          rows: 24,
        },
        l,
      )
      await tick()
      expect(asked[0]).toEqual({
        name: 'terminal.start',
        params: expect.objectContaining({
          pipeline: 'Develop',
          input: 'go',
          runName: 'Fix the login',
        }),
      })
    })

    it('attaches when asked to, and starts nothing', async () => {
      const { asked, connect } = terminalHost()
      const { bus } = connect()
      const { listener: l } = listener()
      new BusTransport(bus).openTerminal(
        { session: 't1', title: 'Shell 1', attach: true, kind: 'Shell', cols: 80, rows: 24 },
        l,
      )
      await tick()
      expect(asked.map((a) => a.name)).toEqual(['terminal.attach'])
    })

    it('ends the session of the host when it is closed, and not when the connection is lost or the view detaches', async () => {
      const { asked, connect } = terminalHost()
      const { bus, client } = connect()
      const { listener: l } = listener()
      const transport = new BusTransport(bus)
      const handle = transport.openTerminal(
        { session: 't1', title: 'Shell 1', kind: 'Shell', cols: 80, rows: 24 },
        l,
      )
      await tick()
      client.close()
      await tick()
      connect(bus)
      await tick()
      handle.detach()
      await tick()
      expect(asked.map((a) => a.name)).not.toContain('terminal.close')
      await transport.closeTerminal('t1')
      expect(asked.at(-1)).toEqual({ name: 'terminal.close', params: { session: 't1' } })
    })

    it('says so when the session is not there to attach to', async () => {
      const { client, host: end } = linkPair()
      serve(end, {
        handlers: {
          'terminal.attach': () => {
            throw new HostError('not_found', 'there is no session t1')
          },
        },
        capabilities: { host: 'fake', shell: true, installActions: false },
      })
      const { seen, listener: l } = listener()
      new BusTransport(new Bus(client)).openTerminal(
        { session: 't1', title: 'Shell 1', attach: true, kind: 'Shell', cols: 80, rows: 24 },
        l,
      )
      await tick()
      expect(seen).toEqual(['error there is no session t1'])
    })
  })

  it('has a message behind every other method', async () => {
    const { transport, asked } = host()
    await transport.cli('synapse-pipeline', ['list'])
    await transport.previewDraft({ kind: 'pipeline', name: 'Develop', text: 'x' })
    await transport.restoreNote('a.md', 'a', 'b')
    await transport.getDiagnosis()
    await transport.getIntegrations()
    await transport.seedVault('/v')
    await transport.inspectVault('/v')
    await transport.graphHealth('synapse@main')
    await transport.startRun('Develop', {})
    await transport.stopRun('exec-1')
    await transport.runRequest('exec-1', { command: 'info' })
    expect(asked.map((a) => a.name)).toEqual([
      'cli',
      'definition.preview',
      'note.restore',
      'diagnose',
      'integrations',
      'vault.seed',
      'vault.inspect',
      'graph.health',
      'run.start',
      'run.stop',
      'run.ask',
    ])
  })
})
