// What Opencode has cost today, read from `opencode stats --days 0 --json`. Only opencode 2.x has
// `--json` on `stats`, so 1.x gives `unavailable` without running it. The mapper reads only the
// top-level `cost` of `shared/examples/_usage-opencode.json`, which follows the shape opencode 2.x
// prints. The Rust host reads it alike in `src-tauri/src/usage_opencode.rs`, and both are tested on
// the same fixture.

import type { UsageReading } from '../shared/usage.ts'

export const OPENCODE_VERSION_ARGS = ['--version']
export const OPENCODE_STATS_ARGS = ['stats', '--days', '0', '--json']
export const OPENCODE_USAGE_TIMEOUT_MS = 15_000

export interface OpencodeUsageDeps {
  findProgram: (name: string) => Promise<string | null>
  run: (
    program: string,
    args: string[],
    options: { cwd: string; timeoutMs: number },
  ) => Promise<{ code: number; stdout: string; stderr: string }>
  workDir: () => Promise<string>
  now: () => Date
}

// Opencode's spend today, read now. No process is started when `opencode` is not on PATH.
export async function readOpencodeUsage(deps: OpencodeUsageDeps): Promise<UsageReading> {
  const program = await deps.findProgram('opencode')
  if (program === null) return failed('not-installed', 'opencode is not on PATH')
  const options = { cwd: await deps.workDir(), timeoutMs: OPENCODE_USAGE_TIMEOUT_MS }

  const version = await run(deps, program, OPENCODE_VERSION_ARGS, options, 'opencode --version')
  if (typeof version !== 'string') return version
  const major = majorVersion(version)
  if (major === null) {
    return failed('unavailable', 'opencode --version did not print a version')
  }
  if (major < 2) return failed('unavailable', 'opencode 1.x has no stats --json; update to 2.x')

  const stats = await run(deps, program, OPENCODE_STATS_ARGS, options, 'opencode stats')
  if (typeof stats !== 'string') return stats
  return mapOpencodeStats(stats, deps.now())
}

// The output of `opencode stats --json` as today's spend, from its top-level `cost`.
export function mapOpencodeStats(json: string, now: Date): UsageReading {
  let stats: unknown
  try {
    stats = JSON.parse(json)
  } catch {
    return failed('unavailable', 'opencode stats did not print JSON')
  }
  const cost =
    stats !== null && typeof stats === 'object'
      ? (stats as Record<string, unknown>).cost
      : undefined
  if (typeof cost !== 'number' || !Number.isFinite(cost) || cost < 0) {
    return failed('unavailable', 'opencode stats gave no cost')
  }
  return {
    harness: 'Opencode',
    kind: 'spend',
    windows: [],
    spend: { amount: cost, period: 'today' },
    observedAt: now.toISOString(),
    state: 'ok',
    reason: null,
  }
}

// The major number of the first `N.N.N` in the text, or null when there is none.
export function majorVersion(text: string): number | null {
  const match = /(\d+)\.\d+\.\d+/.exec(text)
  return match === null ? null : Number(match[1])
}

// Stdout of one run, or the reading that says why there is none.
async function run(
  deps: OpencodeUsageDeps,
  program: string,
  args: string[],
  options: { cwd: string; timeoutMs: number },
  label: string,
): Promise<string | UsageReading> {
  let output: { code: number; stdout: string; stderr: string }
  try {
    output = await deps.run(program, args, options)
  } catch (error) {
    return failed(
      'unavailable',
      `${label}: ${error instanceof Error ? error.message : String(error)}`,
    )
  }
  if (output.code !== 0) {
    const said = output.stderr
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line !== '')
    const exited = `${label} exited with code ${output.code}`
    return failed('unavailable', said === undefined ? exited : `${exited}: ${said}`)
  }
  return output.stdout
}

function failed(state: UsageReading['state'], reason: string): UsageReading {
  return {
    harness: 'Opencode',
    kind: 'spend',
    windows: [],
    spend: null,
    observedAt: null,
    state,
    reason,
  }
}
