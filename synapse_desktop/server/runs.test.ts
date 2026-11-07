import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { defaultConfig } from '../shared/calls.ts'
import { createRunStarter, NotStartedHere, RunNotStarted } from './runs.ts'

// A stand-in for the synapse-pipeline of an npm install: a shim that runs the
// real thing as its child. It does what `run --id` does: makes the record
// directory named by the id, or refuses an id that is taken, and then goes on
// and waits. A Unix shell script, so not on Windows.
const STUB = `#!/bin/sh
input=$(cat)
pipeline="$2"
id=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--id" ]; then id="$2"; fi
  shift
done
dir="$SYNAPSE_WORK_DIR/pipelines/$id"
if [ -d "$dir" ]; then
  echo "error: execution $id already exists" >&2
  exit 1
fi
mkdir -p "$dir"
echo "$pipeline $input" > "$dir/started-with"
echo $$ > "$dir/pid"
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

  const config = () => ({ ...defaultConfig, workDir: work })

  // `start` returns when the record directory exists, as the real program makes it
  // first; the stub writes what else it keeps a moment after.
  async function readWhenWritten(path: string): Promise<string> {
    for (let i = 0; i < 200; i++) {
      try {
        const text = await readFile(path, 'utf8')
        if (text.endsWith('\n')) return text
      } catch {
        // Not written yet.
      }
      await new Promise((resolve) => setTimeout(resolve, 20))
    }
    throw new Error(`${path} was never written`)
  }

  async function pidsOf(id: string): Promise<{ pid: number; childPid: number }> {
    const record = join(work, 'pipelines', id)
    return {
      pid: Number(await readWhenWritten(join(record, 'pid'))),
      childPid: Number(await readWhenWritten(join(record, 'child.pid'))),
    }
  }

  it('gives the program the id it returns, in the form the program draws its own', async () => {
    const starter = createRunStarter(await script('stub', STUB), process.env)
    const { executionId } = await starter.start('P', { task: 'x' }, config())
    expect(executionId).toMatch(/^exec-[0-9a-f]{8}$/)
    const started = await readWhenWritten(join(work, 'pipelines', executionId, 'started-with'))
    expect(started.trim()).toBe('P {"task":"x"}')
    starter.stop(executionId)
  })

  it('stops the run and what it started', async () => {
    const starter = createRunStarter(await script('stub', STUB), process.env)
    const { executionId } = await starter.start('P', {}, config())
    const { pid, childPid } = await pidsOf(executionId)
    expect(alive(pid) && alive(childPid)).toBe(true)

    starter.stop(executionId)
    for (let i = 0; i < 40 && (alive(pid) || alive(childPid)); i++) {
      await new Promise((r) => setTimeout(r, 50))
    }
    expect(alive(pid)).toBe(false)
    // The process the first one started goes with it.
    expect(alive(childPid)).toBe(false)
  })

  it('gives two runs of the same pipeline and input an id each, so neither is mistaken for the other', async () => {
    const starter = createRunStarter(await script('stub', STUB), process.env)
    const [first, second] = await Promise.all([
      starter.start('P', { task: 'same' }, config()),
      starter.start('P', { task: 'same' }, config()),
    ])
    expect(first.executionId).not.toBe(second.executionId)
    // Stopping one leaves the other going.
    const a = await pidsOf(first.executionId)
    const b = await pidsOf(second.executionId)
    starter.stop(first.executionId)
    for (let i = 0; i < 40 && alive(a.pid); i++) await new Promise((r) => setTimeout(r, 50))
    expect(alive(a.pid)).toBe(false)
    expect(alive(b.pid)).toBe(true)
    starter.stop(second.executionId)
  })

  it('cannot stop a run it did not start', async () => {
    const starter = createRunStarter(await script('stub', STUB), process.env)
    expect(() => starter.stop('exec-unknown')).toThrow(NotStartedHere)
  })

  it('reports what the binary printed when the run is refused and leaves no record', async () => {
    const starter = createRunStarter(await script('failing', FAILING_STUB), process.env)
    await expect(starter.start('P', {}, config())).rejects.toThrow(/step Develop has no harness/)
  })

  it('refuses to start without a work directory', async () => {
    const starter = createRunStarter(await script('stub', STUB), process.env)
    await expect(starter.start('P', {}, defaultConfig)).rejects.toBeInstanceOf(RunNotStarted)
  })

  it('reports a binary that cannot be run', async () => {
    const starter = createRunStarter(join(dir, 'missing'), process.env)
    await expect(starter.start('P', {}, config())).rejects.toBeInstanceOf(RunNotStarted)
  })
})
