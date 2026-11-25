import { describe, expect, it } from 'vitest'
import type { RecordedSession } from './activity.ts'
import { fakeTransport } from './fake-transport.ts'
import type { Visit } from './progress.ts'
import { outputPath, problemsOf, readVisitOutput, startsOpen } from './visit-outputs.ts'

const paths = { definitionDirs: [], skillsDir: null, recordsDir: '/w/pipelines' }
const visit: Visit = { n: 2, step: 'Review', outcome: 'Approved', next: null }
const twoTries: RecordedSession[] = [
  { attempt: 1, succeeded: false, transcript: null },
  { attempt: 2, succeeded: true, transcript: null },
]
const PATH = '/w/pipelines/exec-1/outputs/2-Review-2.json'
const OUTPUT = { outcome: 'Approved', summary: 'looks good', data: { note: 'fine' } }

describe('outputPath', () => {
  it('names the file for the attempt of the last session', () => {
    expect(outputPath('/w/pipelines', 'exec-1', visit, twoTries)).toBe(PATH)
  })

  it('is null for a visit with no session', () => {
    expect(outputPath('/w/pipelines', 'exec-1', visit, [])).toBeNull()
  })
})

describe('readVisitOutput', () => {
  it('reads a valid file', async () => {
    const transport = fakeTransport({ paths, files: { [PATH]: JSON.stringify(OUTPUT) } })
    expect(await readVisitOutput(transport, 'exec-1', visit, twoTries)).toEqual({
      status: 'recorded',
      output: OUTPUT,
    })
  })

  it('gives not-recorded for a missing file', async () => {
    const transport = fakeTransport({ paths, files: {} })
    expect(await readVisitOutput(transport, 'exec-1', visit, twoTries)).toEqual({
      status: 'not-recorded',
    })
  })

  it('gives not-recorded when the read fails', async () => {
    const transport = fakeTransport({ paths, files: { [PATH]: JSON.stringify(OUTPUT) } })
    transport.readText = () => Promise.reject(new Error('too_large'))
    expect(await readVisitOutput(transport, 'exec-1', visit, twoTries)).toEqual({
      status: 'not-recorded',
    })
  })

  it('gives not-recorded for a file that is not a result', async () => {
    for (const text of [
      '{not json',
      '[]',
      '{"outcome":"Approved","summary":"x"}',
      '{"outcome":1,"summary":"x","data":{}}',
    ]) {
      const transport = fakeTransport({ paths, files: { [PATH]: text } })
      expect(await readVisitOutput(transport, 'exec-1', visit, twoTries)).toEqual({
        status: 'not-recorded',
      })
    }
  })

  it('reads nothing for a visit with no session', async () => {
    const transport = fakeTransport({ paths, files: { [PATH]: JSON.stringify(OUTPUT) } })
    const read: string[] = []
    transport.readText = (path) => {
      read.push(path)
      return Promise.resolve(JSON.stringify(OUTPUT))
    }
    expect(await readVisitOutput(transport, 'exec-1', visit, [])).toEqual({
      status: 'not-recorded',
    })
    expect(read).toEqual([])
  })
})

describe('problemsOf', () => {
  it('takes file, location and issue from each object entry', () => {
    const data = {
      problems: [
        { file: 'a.txt', location: 12, issue: 'one issue' },
        { issue: 'no place' },
        'not an object',
        null,
      ],
    }
    expect(problemsOf(data)).toEqual([
      { file: 'a.txt', location: '12', issue: 'one issue' },
      { file: null, location: null, issue: 'no place' },
    ])
  })

  it('is empty when problems is not a list', () => {
    expect(problemsOf({ problems: 'none' })).toEqual([])
    expect(problemsOf({})).toEqual([])
  })
})

describe('startsOpen', () => {
  it('opens the root', () => {
    expect(startsOpen(0, 3)).toBe(true)
  })

  it('opens a small node at the first level', () => {
    expect(startsOpen(1, 20)).toBe(true)
  })

  it('folds a node deeper than the first level', () => {
    expect(startsOpen(2, 1)).toBe(false)
  })

  it('folds a node with more than 20 entries at any depth', () => {
    expect(startsOpen(0, 21)).toBe(false)
    expect(startsOpen(1, 21)).toBe(false)
  })
})
