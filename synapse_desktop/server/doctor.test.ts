import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { AppConfig, CliResult } from '../shared/transport.ts'
import { combinedPath, diagnose, forgetLoginPath, readLoginPath } from './doctor.ts'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-doctor-'))
  forgetLoginPath()
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const config = { workDir: null, definitionPaths: [], env: {} } as unknown as AppConfig

const document = (checks: object[], counts = { ok: 1, warn: 0, fail: 0 }) =>
  JSON.stringify({ format: 'synapse-doctor/v1', checks, counts })

const git = { key: 'git', name: 'git', status: 'ok', detail: 'git version 2', value: '' }

async function shell(body: string): Promise<string> {
  const path = join(dir, 'shell')
  await writeFile(path, `#!/bin/sh\n${body}\n`)
  await chmod(path, 0o755)
  return path
}

describe('the PATH of a login shell', () => {
  it('is what the shell prints between the marks, whatever its start-up files print', async () => {
    const path = await shell(
      `echo "welcome"; printf '%s' "__SYNAPSE_PATH__/opt/a:/opt/b__SYNAPSE_PATH__"; echo " bye"`,
    )
    expect(await readLoginPath(path)).toBe('/opt/a:/opt/b')
  })

  it('is asked as an interactive login shell, so that what its start-up files add is there', async () => {
    const path = await shell(
      `case "$1" in -ilc) printf '%s' "__SYNAPSE_PATH__/ok__SYNAPSE_PATH__";; esac`,
    )
    expect(await readLoginPath(path)).toBe('/ok')
  })

  it('is nothing when the shell says nothing, fails, or is not there', async () => {
    expect(await readLoginPath(await shell('echo nothing'))).toBeNull()
    expect(await readLoginPath(await shell('exit 3'))).toBeNull()
    expect(await readLoginPath(join(dir, 'no-such-shell'))).toBeNull()
  })
})

describe('the PATH the doctor is given', () => {
  it('has the login shell directories first, then this process\u2019s, each once', () => {
    expect(combinedPath('/a:/b', '/b:/c')).toBe(['/a', '/b', '/c'].join(delimiter))
  })

  it('is this process\u2019s alone without a login shell, and drops empty entries', () => {
    expect(combinedPath(null, '/x::/y')).toBe(['/x', '/y'].join(delimiter))
    expect(combinedPath(null, undefined)).toBe('')
  })
})

describe('diagnose', () => {
  function runner(result: CliResult) {
    const calls: { args: readonly string[]; env: Record<string, string> | undefined }[] = []
    return {
      calls,
      runCli: (run: { args: readonly string[]; env?: Record<string, string> }) => {
        calls.push({ args: run.args, env: run.env })
        return Promise.resolve(result)
      },
    }
  }

  it('asks for the install only, as JSON, with the PATH of the login shell added', async () => {
    const { calls, runCli } = runner({ code: 0, stdout: document([git]), stderr: '' })
    const diagnosis = await diagnose(config, {
      runCli,
      loginPath: () => Promise.resolve('/login/bin'),
      env: { PATH: '/process/bin' },
    })
    expect(calls[0]?.args).toEqual(['doctor', '--install', '--format', 'json'])
    expect(calls[0]?.env?.PATH).toBe(['/login/bin', '/process/bin'].join(delimiter))
    expect(diagnosis.findings).toEqual([git])
    expect(diagnosis.counts).toEqual({ ok: 1, warn: 0, fail: 0 })
  })

  it('has the findings of a failed doctor too, which is exit code 1 and a document', async () => {
    const failed = { key: 'harness', name: 'harness', status: 'fail', detail: 'none', value: '' }
    const { runCli } = runner({
      code: 1,
      stdout: document([failed], { ok: 0, warn: 0, fail: 1 }),
      stderr: '',
    })
    const diagnosis = await diagnose(config, { runCli, loginPath: () => Promise.resolve(null) })
    expect(diagnosis.findings[0]?.status).toBe('fail')
    expect(diagnosis.counts.fail).toBe(1)
  })

  it('does not ask a login shell on Windows, which has none', async () => {
    const { calls, runCli } = runner({ code: 0, stdout: document([git]), stderr: '' })
    await diagnose(config, {
      runCli,
      platform: 'win32',
      env: { PATH: 'C:\\bin', SHELL: '/bin/false' },
    })
    expect(calls[0]?.env?.PATH).toBe('C:\\bin')
  })

  it('says what the program said when it printed no document', async () => {
    const { runCli } = runner({ code: 2, stdout: '', stderr: 'usage: synapse doctor\n' })
    await expect(
      diagnose(config, { runCli, loginPath: () => Promise.resolve(null) }),
    ).rejects.toThrow('usage: synapse doctor')
    const silent = runner({ code: 0, stdout: '', stderr: '' })
    await expect(
      diagnose(config, { runCli: silent.runCli, loginPath: () => Promise.resolve(null) }),
    ).rejects.toThrow('printed nothing')
  })

  it('refuses a document of a format it does not know', async () => {
    const { runCli } = runner({
      code: 0,
      stdout: JSON.stringify({ format: 'synapse-doctor/v2', checks: [], counts: {} }),
      stderr: '',
    })
    await expect(
      diagnose(config, { runCli, loginPath: () => Promise.resolve(null) }),
    ).rejects.toThrow('does not know')
  })
})
