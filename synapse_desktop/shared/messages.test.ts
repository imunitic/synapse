import { describe, expect, it } from 'vitest'
import { envelopeExamples, examples } from './examples.ts'
import { isMessageName, messages, methodHomes, type MessageName } from './messages.ts'
import {
  clientMessageSchema,
  hostMessageSchema,
  PROTOCOL_VERSION,
  topicSchema,
} from './protocol.ts'

const envelope = envelopeExamples

describe('the messages', () => {
  it('each have an example, and no example is of a message there is not', () => {
    expect(examples.map((e) => e.name).sort()).toEqual(Object.keys(messages).sort())
    for (const example of examples) expect(isMessageName(example.name)).toBe(true)
  })

  it('accept their example, parameters and result', () => {
    for (const { name, params, result } of examples) {
      const message = messages[name as MessageName]
      expect(message.params.safeParse(params).success, `${name} params`).toBe(true)
      expect(message.result.safeParse(result).success, `${name} result`).toBe(true)
    }
  })

  it('refuse what is not what they take: no parameters at all, a number, and a result of another message', () => {
    for (const { name, result } of examples) {
      const message = messages[name as MessageName]
      expect(message.params.safeParse(42).success, `${name} params 42`).toBe(false)
      expect(message.params.safeParse(undefined).success, `${name} params undefined`).toBe(false)
      expect(message.result.safeParse(42).success, `${name} result 42`).toBe(false)
      // `null` is the answer of a message that has nothing to say, and of none that has.
      expect(message.result.safeParse(null).success, `${name} result null`).toBe(result === null)
    }
  })

  it('refuse a parameter of the wrong kind, from each example with its first member spoiled', () => {
    for (const { name, params } of examples) {
      if (typeof params !== 'object' || params === null) continue
      const [first] = Object.keys(params)
      if (first === undefined) continue
      const spoiled = { ...params, [first]: 42 }
      expect(
        messages[name as MessageName].params.safeParse(spoiled).success,
        `${name} ${first}`,
      ).toBe(false)
    }
  })

  it('have a place for every method of the interface the pages used', () => {
    expect(Object.keys(methodHomes)).toHaveLength(44)
    for (const [method, home] of Object.entries(methodHomes)) {
      expect(home === 'subscribe' || isMessageName(home), method).toBe(true)
    }
  })
})

describe('the envelope', () => {
  it('reads a client message of each kind, and refuses one that is not', () => {
    for (const key of ['request', 'subscribe']) {
      expect(clientMessageSchema.safeParse(envelope[key]).success, key).toBe(true)
    }
    expect(
      clientMessageSchema.safeParse({ kind: 'stream', session: 't1', data: { type: 'input' } })
        .success,
    ).toBe(true)
    expect(
      clientMessageSchema.safeParse({ kind: 'unsubscribe', topic: 'files.vault' }).success,
    ).toBe(true)
    expect(clientMessageSchema.safeParse({ kind: 'request', id: '', name: 'x' }).success).toBe(
      false,
    )
    expect(clientMessageSchema.safeParse({ kind: 'subscribe', topic: 'files.etc' }).success).toBe(
      false,
    )
    expect(clientMessageSchema.safeParse({ kind: 'launch' }).success).toBe(false)
  })

  it('reads a message of the host of each kind', () => {
    for (const key of ['hello', 'reply', 'error', 'event', 'stream']) {
      expect(hostMessageSchema.safeParse(envelope[key]).success, key).toBe(true)
    }
    expect((envelope.hello as { protocol: number }).protocol).toBe(PROTOCOL_VERSION)
  })

  it('has a reply with a result or an error, not both and not neither', () => {
    expect(hostMessageSchema.safeParse({ kind: 'reply', id: 'r', result: null }).success).toBe(true)
    expect(hostMessageSchema.safeParse({ kind: 'reply', id: 'r' }).success).toBe(false)
    expect(
      hostMessageSchema.safeParse({
        kind: 'reply',
        id: 'r',
        result: 1,
        error: { code: 'internal', message: 'x' },
      }).success,
    ).toBe(false)
    expect(
      hostMessageSchema.safeParse({
        kind: 'reply',
        id: 'r',
        error: { code: 'teapot', message: 'x' },
      }).success,
    ).toBe(false)
  })

  it('names the topics there are, files of a place and the events of a run', () => {
    for (const topic of [
      'files.work',
      'files.definitions',
      'files.vault',
      'run.exec-1a2b',
      'note-run.abc_1',
    ]) {
      expect(topicSchema.safeParse(topic).success, topic).toBe(true)
    }
    for (const topic of [
      'files.root',
      'run.',
      'run.a b',
      'anything',
      'note-run.',
      'note-run.a/b',
    ]) {
      expect(topicSchema.safeParse(topic).success, topic).toBe(false)
    }
  })
})

describe('the run id of an agent run', () => {
  const base = {
    definition: {
      kind: 'definition',
      what: 'agent',
      prompt: 'p',
      definitions: [],
      skills: [],
    },
    note: { kind: 'note', what: 'note', prompt: 'p' },
    'note-edit': { kind: 'note-edit', path: 'a.md', prompt: 'p' },
  }

  it('is accepted by each of the three kinds', () => {
    for (const [kind, params] of Object.entries(base)) {
      const parsed = messages['agent.run'].params.safeParse({ ...params, run: 'abc-1_X' })
      expect(parsed.success, kind).toBe(true)
      expect(messages['agent.run'].params.safeParse(params).success, `${kind} without`).toBe(true)
    }
  })

  it('is refused with a slash, empty, or 65 characters', () => {
    for (const [kind, params] of Object.entries(base)) {
      for (const run of ['a/b', '', 'a'.repeat(65)]) {
        expect(
          messages['agent.run'].params.safeParse({ ...params, run }).success,
          `${kind} ${run}`,
        ).toBe(false)
      }
    }
  })

  it('is what agent.stop needs', () => {
    expect(messages['agent.stop'].params.safeParse({ run: 'abc' }).success).toBe(true)
    expect(messages['agent.stop'].params.safeParse({}).success).toBe(false)
    expect(messages['agent.stop'].params.safeParse({ run: 'a/b' }).success).toBe(false)
  })
})
