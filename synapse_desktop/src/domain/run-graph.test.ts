import { describe, expect, it } from 'vitest'
import type { CliResult, RunAnswer, Transport } from '../../shared/transport.ts'
import { fakeTransport } from './fake-transport.ts'
import { BROKEN_ONE_STDERR, DEVELOP_FEATURE_SHOW } from './fixtures.ts'
import { describeRun } from './run-graph.ts'

function transportWith(options: { socket: RunAnswer | Error; show: CliResult }): Transport {
  const base = fakeTransport({
    files: {},
    paths: { definitionDirs: [], skillsDir: null, recordsDir: null },
  })
  return {
    ...base,
    runRequest: () =>
      options.socket instanceof Error
        ? Promise.reject(options.socket)
        : Promise.resolve(options.socket),
    cli: () => Promise.resolve(options.show),
  }
}

const shown: CliResult = { code: 0, stdout: DEVELOP_FEATURE_SHOW, stderr: '' }

describe('describeRun', () => {
  it('uses the description a run that is going gives, and says it is exact', async () => {
    const graph = await describeRun(
      transportWith({
        socket: { ok: true, result: JSON.parse(DEVELOP_FEATURE_SHOW) },
        show: { code: 1, stdout: '', stderr: 'must not be asked' },
      }),
      'exec-1',
      'Develop_Feature',
    )
    expect(graph).toMatchObject({ ok: true, exact: true })
  })

  it('falls back to the definition as it is now when nothing answers', async () => {
    const graph = await describeRun(
      transportWith({ socket: new Error('not listening'), show: shown }),
      'exec-1',
      'Develop_Feature',
    )
    expect(graph).toMatchObject({ ok: true, exact: false })
  })

  it('falls back when the run answers something that is not a description', async () => {
    const graph = await describeRun(
      transportWith({ socket: { ok: true, result: { nope: 1 } }, show: shown }),
      'exec-1',
      'Develop_Feature',
    )
    expect(graph).toMatchObject({ ok: true, exact: false })
  })

  it('returns the problems when the definition cannot be described either', async () => {
    const graph = await describeRun(
      transportWith({
        socket: new Error('not listening'),
        show: { code: 1, stdout: '', stderr: BROKEN_ONE_STDERR },
      }),
      'exec-1',
      'Broken_One',
    )
    expect(graph.ok).toBe(false)
    if (!graph.ok) expect(graph.problems).toHaveLength(3)
  })
})
