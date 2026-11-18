import { describe, expect, it } from 'vitest'
import type { CliResult } from '../../shared/transport.ts'
import { fakeTransport } from './fake-transport.ts'
import { changeLabel, readRunChanges } from './run-changes.ts'

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

const document = (steps: unknown[]) =>
  JSON.stringify({
    format: 'synapse-pipeline-changes/v1',
    execution_id: 'exec-1',
    directory: '/work/widget',
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

describe('changeLabel', () => {
  const change = (step: string, visit: number, attempt = 1) => ({
    step,
    visit,
    attempt,
    set: { files: [], diffs: new Map() },
  })

  it('is the step, and says which visit and try only when the step has several', () => {
    const all = [change('Develop', 1), change('Review', 2), change('Develop', 3, 2)]
    expect(changeLabel(all[1]!, all)).toBe('Review')
    expect(changeLabel(all[0]!, all)).toBe('Develop · visit 1')
    expect(changeLabel(all[2]!, all)).toBe('Develop · visit 3, try 2')
  })
})
