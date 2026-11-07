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

// A run that is over: nothing answers on its socket, and its record may hold
// the description it ran with.
function finishedRun(files: Record<string, string>, show: CliResult): Transport {
  const base = fakeTransport({
    files,
    paths: { definitionDirs: [], skillsDir: null, recordsDir: '/w/pipelines' },
  })
  return { ...base, cli: () => Promise.resolve(show) }
}

describe('describeRun', () => {
  it('uses the description a run that is going gives, and says it is exact', async () => {
    const graph = await describeRun(
      transportWith({
        socket: { ok: true, result: JSON.parse(DEVELOP_FEATURE_SHOW) },
        show: { code: 1, stdout: '', stderr: 'must not be asked' },
      }),
      'exec-1',
      'Develop_Feature',
      true,
    )
    expect(graph).toMatchObject({ ok: true, exact: true })
  })

  it('falls back to the definition as it is now when nothing answers', async () => {
    const graph = await describeRun(
      transportWith({ socket: new Error('not listening'), show: shown }),
      'exec-1',
      'Develop_Feature',
      true,
    )
    expect(graph).toMatchObject({ ok: true, exact: false })
  })

  it('falls back when the run answers something that is not a description', async () => {
    const graph = await describeRun(
      transportWith({ socket: { ok: true, result: { nope: 1 } }, show: shown }),
      'exec-1',
      'Develop_Feature',
      true,
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
      true,
    )
    expect(graph.ok).toBe(false)
    if (!graph.ok) expect(graph.problems).toHaveLength(3)
  })

  it('uses the description the record of a finished run keeps, and says it is exact', async () => {
    const graph = await describeRun(
      finishedRun(
        { '/w/pipelines/exec-1/description.json': DEVELOP_FEATURE_SHOW },
        { code: 1, stdout: '', stderr: 'must not be asked' },
      ),
      'exec-1',
      'Develop_Feature',
      false,
    )
    expect(graph).toMatchObject({ ok: true, exact: true })
  })

  it('prefers the record to the definition, which may have changed', async () => {
    const changed = JSON.parse(DEVELOP_FEATURE_SHOW) as { steps: { name: string }[] }
    changed.steps = changed.steps.slice(0, 1)
    const graph = await describeRun(
      finishedRun(
        { '/w/pipelines/exec-1/description.json': DEVELOP_FEATURE_SHOW },
        { code: 0, stdout: JSON.stringify(changed), stderr: '' },
      ),
      'exec-1',
      'Develop_Feature',
      false,
    )
    expect(graph.ok && graph.description.steps.map((s) => s.name)).toEqual([
      'Develop',
      'Test',
      'Review',
    ])
  })

  it('falls back to the definition when the record holds no usable description', async () => {
    const records: Record<string, string>[] = [
      {},
      { '/w/pipelines/exec-1/description.json': '{"torn"' },
    ]
    for (const files of records) {
      const graph = await describeRun(finishedRun(files, shown), 'exec-1', 'Develop_Feature', false)
      expect(graph).toMatchObject({ ok: true, exact: false })
    }
  })

  it('does not ask the socket of a run that its record says is over', async () => {
    const graph = await describeRun(
      transportWith({
        socket: { ok: true, result: JSON.parse(DEVELOP_FEATURE_SHOW) },
        show: shown,
      }),
      'exec-1',
      'Develop_Feature',
      false,
    )
    // The socket was not asked, so the description is the definition's.
    expect(graph).toMatchObject({ ok: true, exact: false })
  })
})
