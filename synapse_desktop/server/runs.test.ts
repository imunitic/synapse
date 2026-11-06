import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { defaultConfig } from '../shared/calls.ts'
import { canonical, createRunStarter, isRunOf, NotStartedHere, RunNotStarted } from './runs.ts'

describe('canonical', () => {
  it('gives the same text for objects that differ only in key order', () => {
    expect(canonical({ a: 1, b: { y: 2, x: 3 } })).toBe(canonical({ b: { x: 3, y: 2 }, a: 1 }))
  })

  it('tells different documents apart', () => {
    expect(canonical({ a: 1 })).not.toBe(canonical({ a: 2 }))
    expect(canonical([1, 2])).not.toBe(canonical([2, 1]))
    expect(canonical(null)).toBe('null')
  })
})

describe('isRunOf', () => {
  const summary = { pipeline: 'P', state: { initial_input: { task: 'x', n: 1 } } }

  it('accepts the record of this pipeline with this input, whatever the key order', () => {
    expect(isRunOf(summary, 'P', { n: 1, task: 'x' })).toBe(true)
  })

  it('refuses another pipeline, another input and a record that is not a summary', () => {
    expect(isRunOf(summary, 'Q', { task: 'x', n: 1 })).toBe(false)
    expect(isRunOf(summary, 'P', { task: 'y', n: 1 })).toBe(false)
    expect(isRunOf(null, 'P', {})).toBe(false)
    expect(isRunOf({ pipeline: 'P' }, 'P', {})).toBe(false)
  })
})

// A stand-in for the synapse-pipeline of an npm install: a shim that runs the
// real thing as its child. It makes the record of a run that goes on, as the
// real one does, and waits. A Unix shell script, so not on Windows.
const STUB = `#!/bin/sh
input=$(cat)
dir="$SYNAPSE_WORK_DIR/pipelines/exec-stub$$"
mkdir -p "$dir"
printf '{"pipeline":"%s","state":{"initial_input":%s}}' "$2" "$input" > "$dir/execution.json"
sleep 30 &
echo $! > "$dir/child.pid"
wait
`

const FAILING_STUB = `#!/bin/sh
cat > /dev/null
echo "error: step Develop has no harness" >&2
exit 1
`

describe.skipIf(process.platform === 'win32')('createRunStarter', () => {
  let dir: string
  let work: string

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-runs-'))
    work = join(dir, 'work')
    await mkdir(join(work, 'pipelines'), { recursive: true })
  })

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  async function script(name: string, text: string): Promise<string> {
    const path = join(dir, name)
    await writeFile(path, text)
    await chmod(path, 0o755)
    return path
  }

  function alive(pid: number): boolean {
    try {
      process.kill(pid, 0)
      return true
    } catch {
      return false
    }
  }

  it('returns the id of the record its own run made, and stop ends the run and what it started', async () => {
    const starter = createRunStarter(await script('stub', STUB), process.env)
    // A record that was there before, and is for the same pipeline and input.
    await mkdir(join(work, 'pipelines', 'exec-older'))
    await writeFile(
      join(work, 'pipelines', 'exec-older', 'execution.json'),
      '{"pipeline":"P","state":{"initial_input":{"task":"x"}}}',
    )

    const { executionId } = await starter.start(
      'P',
      { task: 'x' },
      { ...defaultConfig, workDir: work },
    )
    expect(executionId).toMatch(/^exec-stub\d+$/)

    const pid = Number(executionId.slice('exec-stub'.length))
    const childPid = Number(
      await readFile(join(work, 'pipelines', executionId, 'child.pid'), 'utf8'),
    )
    expect(alive(pid)).toBe(true)
    expect(alive(childPid)).toBe(true)

    starter.stop(executionId)
    for (let i = 0; i < 40 && (alive(pid) || alive(childPid)); i++) {
      await new Promise((r) => setTimeout(r, 50))
    }
    expect(alive(pid)).toBe(false)
    // The process the first one started goes with it.
    expect(alive(childPid)).toBe(false)
  })

  it('cannot stop a run it did not start', async () => {
    const starter = createRunStarter(await script('stub', STUB), process.env)
    expect(() => starter.stop('exec-unknown')).toThrow(NotStartedHere)
  })

  it('reports what the binary printed when the run ends without a record', async () => {
    const starter = createRunStarter(await script('failing', FAILING_STUB), process.env)
    await expect(starter.start('P', {}, { ...defaultConfig, workDir: work })).rejects.toThrow(
      /step Develop has no harness/,
    )
  })

  it('refuses to start without a work directory', async () => {
    const starter = createRunStarter(await script('stub', STUB), process.env)
    await expect(starter.start('P', {}, defaultConfig)).rejects.toBeInstanceOf(RunNotStarted)
  })

  it('reports a binary that cannot be run', async () => {
    const starter = createRunStarter(join(dir, 'missing'), process.env)
    await expect(
      starter.start('P', {}, { ...defaultConfig, workDir: work }),
    ).rejects.toBeInstanceOf(RunNotStarted)
  })
})
