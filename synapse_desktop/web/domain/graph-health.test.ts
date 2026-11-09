import { describe, expect, it } from 'vitest'
import type { GraphCheck, GraphHealth } from '../../shared/transport.ts'
import {
  anyCheckFailed,
  findingsOf,
  groupFindings,
  healthLine,
  mergeReasons,
  nodesNeedingAttention,
  splitReason,
  staleCount,
} from './graph-health.ts'

const found = (...nodes: string[]): GraphCheck => ({
  ok: true,
  findings: nodes.map((node) => ({ node, reason: 'x' })),
})
const clean: GraphCheck = { ok: true, findings: [] }
const failed: GraphCheck = { ok: false, error: 'could not run' }

const health = (stale: GraphCheck, drift: GraphCheck, grounding: GraphCheck): GraphHealth => ({
  stale,
  drift,
  grounding,
})

describe('the health of a graph', () => {
  it('names the nodes any check found, each once and sorted, and not the repository', () => {
    const h = health(found('B', 'A'), found('(repo)', 'A', 'C'), found('B'))
    expect(nodesNeedingAttention(h)).toEqual(['A', 'B', 'C'])
    expect(staleCount(h)).toBe(2)
  })

  it('has no findings from a check that could not run, and says one could not', () => {
    expect(findingsOf(failed)).toEqual([])
    expect(anyCheckFailed(health(clean, failed, clean))).toBe(true)
    expect(anyCheckFailed(health(clean, clean, clean))).toBe(false)
  })

  it('has a line when it is not clean, saying stale first, and none when it is', () => {
    expect(healthLine('a@b', health(clean, clean, clean))).toBeNull()
    expect(healthLine('a@b', health(found('A'), clean, clean))).toBe('a@b: 1 node is stale')
    expect(healthLine('a@b', health(found('A', 'B'), clean, clean))).toBe('a@b: 2 nodes are stale')
    expect(healthLine('a@b', health(clean, found('A'), clean))).toBe('a@b: 1 node needs a look')
    expect(healthLine('a@b', health(clean, found('(repo)'), clean))).toBeNull()
    expect(healthLine('a@b', health(found('A'), failed, clean))).toBe('a@b: a check could not run')
  })
})

describe('the reason of a finding', () => {
  it('keeps the files a long list names out of the sentence', () => {
    expect(splitReason('source files gone: a.adb b.adb c.ads d.ads')).toEqual({
      text: 'source files gone (4)',
      items: ['a.adb', 'b.adb', 'c.ads', 'd.ads'],
    })
  })

  it('keeps a reason that names few files, or none, as it is', () => {
    expect(splitReason('source files gone: a.adb b.adb c.ads')).toEqual({
      text: 'source files gone: a.adb b.adb c.ads',
      items: [],
    })
    expect(splitReason('content changed')).toEqual({ text: 'content changed', items: [] })
  })
})

describe('the findings of a check by node', () => {
  it('are one entry for each node, in the order they came, with each reason once', () => {
    expect(
      groupFindings([
        { node: 'Build', reason: 'grounding changed (8)' },
        { node: 'CLI', reason: 'grounding file gone: a.ads' },
        { node: 'Build', reason: 'grounding file gone: b.ads' },
        { node: 'Build', reason: 'grounding changed (8)' },
      ]),
    ).toEqual([
      { node: 'Build', reasons: ['grounding changed (8)', 'grounding file gone: b.ads'] },
      { node: 'CLI', reasons: ['grounding file gone: a.ads'] },
    ])
  })

  it('keeps the repository findings together under its own name', () => {
    expect(
      groupFindings([
        { node: '(repo)', reason: 'one' },
        { node: 'Build', reason: 'x' },
        { node: '(repo)', reason: 'two' },
      ]),
    ).toEqual([
      { node: '(repo)', reasons: ['one', 'two'] },
      { node: 'Build', reasons: ['x'] },
    ])
  })

  it('are none for none', () => {
    expect(groupFindings([])).toEqual([])
  })
})

describe('the reasons of a node, made one for each kind', () => {
  it('put the files of reasons of one kind together, once each', () => {
    expect(
      mergeReasons([
        'grounding changed: a b c d',
        'grounding changed: c d e f',
        'grounding changed: g h i j',
      ]),
    ).toEqual([
      { text: 'grounding changed (10)', items: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'] },
    ])
  })

  it('keep the files in the line when there are few, and keep other kinds apart', () => {
    expect(
      mergeReasons(['source files gone: a b', 'content changed', 'source files gone: b c']),
    ).toEqual([
      { text: 'source files gone: a b c', items: [] },
      { text: 'content changed', items: [] },
    ])
  })

  it('keep a reason that lists no files once', () => {
    expect(mergeReasons(['no commit recorded', 'no commit recorded'])).toEqual([
      { text: 'no commit recorded', items: [] },
    ])
    expect(mergeReasons([])).toEqual([])
  })
})
