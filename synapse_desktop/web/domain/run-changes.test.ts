import { describe, expect, it } from 'vitest'
import type { CliResult } from '../../shared/transport.ts'
import { fakeTransport } from './fake-transport.ts'
import { readRunChanges } from './run-changes.ts'

const PATCH = `diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1 +1,2 @@
 one
+two
`

function answering(result: CliResult, seen: string[][] = []) {
  return fakeTransport({
    paths: { definitionDirs: [], skillsDir: null, recordsDir: null },
    files: {},
    cli: (binary, args) => {
      seen.push([binary, ...args])
      return result
    },
  })
}

const document = (steps: unknown[], more: Record<string, unknown> = {}) =>
  JSON.stringify({
    format: 'synapse-pipeline-changes/v1',
    execution_id: 'exec-1',
    directory: '/work/widget',
    ...more,
    steps,
  })

describe('readRunChanges', () => {
  it('asks the CLI for the changes of the run as data, and reads each patch into its files', async () => {
    const seen: string[][] = []
    const stdout = document([
      { step: 'Develop', visit: 1, attempt: 1, patch: PATCH },
      { step: 'Review', visit: 2, attempt: 1, patch: PATCH },
    ])
    const changes = await readRunChanges(answering({ code: 0, stdout, stderr: '' }, seen), 'exec-1')
    expect(seen).toEqual([['synapse-pipeline', 'changes', 'exec-1', '--format', 'json']])
    expect(changes.directory).toBe('/work/widget')
    expect(changes.changes.map((c) => [c.step, c.visit, c.set.files.map((f) => f.path)])).toEqual([
      ['Develop', 1, ['a.txt']],
      ['Review', 2, ['a.txt']],
    ])
  })

  it('passes the step it is asked for, so that the running attempt of it is included', async () => {
    const seen: string[][] = []
    const stdout = document([{ step: 'Develop', visit: 1, attempt: 2, patch: PATCH }])
    await readRunChanges(answering({ code: 0, stdout, stderr: '' }, seen), 'exec-1', 'Develop')
    expect(seen).toEqual([
      ['synapse-pipeline', 'changes', 'exec-1', '--step', 'Develop', '--format', 'json'],
    ])
  })

  it('reads the status of the run and the snapshots it pinned', async () => {
    const stdout = document([], {
      status: 'completed',
      snapshots: { start: 'aaa111', end: 'bbb222' },
    })
    const changes = await readRunChanges(answering({ code: 0, stdout, stderr: '' }), 'exec-1')
    expect(changes.status).toBe('completed')
    expect(changes.snapshots).toEqual({ start: 'aaa111', end: 'bbb222' })
  })

  it('takes an answer from an engine without status or snapshots as incomplete, with none', async () => {
    const stdout = document([])
    const changes = await readRunChanges(answering({ code: 0, stdout, stderr: '' }), 'exec-1')
    expect(changes.status).toBe('incomplete')
    expect(changes.snapshots).toEqual({ start: null, end: null })
  })

  it('leaves out a patch that has no files in it', async () => {
    const stdout = document([{ step: 'Develop', visit: 1, attempt: 1, patch: '' }])
    const changes = await readRunChanges(answering({ code: 0, stdout, stderr: '' }), 'exec-1')
    expect(changes.changes).toEqual([])
  })

  it('says what the CLI said when it could not, and refuses an answer it does not know', async () => {
    await expect(
      readRunChanges(
        answering({ code: 1, stdout: '', stderr: "error: there is no record of execution 'x'\n" }),
        'x',
      ),
    ).rejects.toThrow("there is no record of execution 'x'")
    await expect(
      readRunChanges(answering({ code: 0, stdout: 'x', stderr: '' }), 'x'),
    ).rejects.toThrow('did not answer JSON')
    await expect(
      readRunChanges(answering({ code: 0, stdout: '{"format":"other"}', stderr: '' }), 'x'),
    ).rejects.toThrow('format this app does not know')
  })
})
