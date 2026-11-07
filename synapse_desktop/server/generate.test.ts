import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { GenerateRequest } from '../shared/transport.ts'
import { CallError, handleCall, type Context } from './calls.ts'
import {
  agentCommand,
  findPipelineSkill,
  promptFor,
  referenceFrom,
  systemFor,
  textOf,
  type AgentRun,
} from './generate.ts'

const SKILL = [
  '---',
  'name: synapse-pipeline',
  '---',
  '# synapse-pipeline',
  '## Crafting a pipeline',
  'steps about files',
  '## Definitions',
  'A definition file has the extension .synapse.',
  '## Results and routing',
  'Outcomes route.',
  '## Trying a pipeline without agents',
  'scripted',
].join('\n')

const request: GenerateRequest = {
  kind: 'pipeline',
  prompt: '  Build, then review.  ',
  definitions: [{ name: 'Reviewer', kind: 'agent' }],
  skills: ['review-code'],
}

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-generate-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('what the agent is given', () => {
  it('has the reference part of the skill and not the steps about files', () => {
    const system = systemFor(request, SKILL)
    expect(system).toContain('A definition file has the extension .synapse.')
    expect(system).toContain('Outcomes route.')
    expect(system).not.toContain('steps about files')
    expect(system).not.toContain('scripted')
  })

  it('names what exists, so that it is reused and its names are not taken', () => {
    const prompt = promptFor(request)
    expect(prompt).toContain('Build, then review.')
    expect(prompt).toContain('- agent Reviewer')
    expect(promptFor({ ...request, kind: 'skill' })).toContain('review-code')
    expect(promptFor({ ...request, kind: 'skill' })).not.toContain('Reviewer')
  })

  it('needs no skill file to write a skill', () => {
    expect(systemFor({ ...request, kind: 'skill' }, '')).toContain('SKILL.md')
  })

  it('refuses a skill whose layout it does not know', () => {
    expect(() => referenceFrom('# nothing here')).toThrow(/layout/)
  })

  it('finds the headings in the skill that ships with the program', async () => {
    const real = await readFile(
      join(import.meta.dirname, '../../packages/synapse-pipeline/skills/synapse-pipeline/SKILL.md'),
      'utf8',
    )
    expect(referenceFrom(real)).toContain('## Results and routing')
  })
})

describe('agentCommand', () => {
  const run = { system: 'RULES', prompt: 'ASK' }

  it('gives Claude the instructions as a system prompt and no tools', () => {
    const made = agentCommand({ ...run, harness: 'Claude' })
    expect(made.program).toBe('claude')
    expect(made.args).toEqual(
      expect.arrayContaining(['--tools', '', '--append-system-prompt', 'RULES']),
    )
    expect(made.stdin).toBe('ASK')
  })

  it('puts the instructions before the prompt for Codex, in a read-only sandbox', () => {
    const made = agentCommand({ ...run, harness: 'Codex' })
    expect(made.args).toEqual(['exec', '--ephemeral', '--skip-git-repo-check', '-s', 'read-only'])
    expect(made.stdin).toBe('RULES\n\nASK')
  })

  it('denies OpenCode every tool that changes or reaches out', () => {
    const made = agentCommand({ ...run, harness: 'Opencode' })
    expect(made.args.at(-1)).toBe('RULES\n\nASK')
    expect(JSON.parse(made.env.OPENCODE_CONFIG_CONTENT ?? '')).toEqual({
      permission: { edit: 'deny', bash: 'deny', webfetch: 'deny', external_directory: 'deny' },
    })
  })
})

describe('textOf', () => {
  it('takes a code fence off a reply that has one', () => {
    expect(textOf('```synapse\nAgent A [Prompt => "x"];\n```\n')).toBe('Agent A [Prompt => "x"];\n')
    expect(textOf('Agent A [Prompt => "x"];')).toBe('Agent A [Prompt => "x"];\n')
  })
})

describe('findPipelineSkill', () => {
  it('reads the skill of the package the launcher on PATH belongs to', async () => {
    const pkg = join(dir, 'lib', 'pkg')
    await mkdir(join(pkg, 'bin'), { recursive: true })
    await mkdir(join(pkg, 'skills', 'synapse-pipeline'), { recursive: true })
    await writeFile(join(pkg, 'bin', 'synapse-pipeline'), '')
    await writeFile(join(pkg, 'skills', 'synapse-pipeline', 'SKILL.md'), SKILL)
    await mkdir(join(dir, 'bin'))
    await symlink(join(pkg, 'bin', 'synapse-pipeline'), join(dir, 'bin', 'synapse-pipeline'))
    // A launcher without a skill beside it does not stop the search.
    await mkdir(join(dir, 'other'))
    await writeFile(join(dir, 'other', 'synapse-pipeline'), '')
    const found = await findPipelineSkill(`${join(dir, 'other')}:${join(dir, 'bin')}`)
    expect(found).toBe(SKILL)
  })

  it('says so when there is none', async () => {
    await expect(findPipelineSkill(dir)).rejects.toThrow(/not found/)
  })
})

describe('generateDefinition', () => {
  function contextWith(
    agent: (run: AgentRun) => ReturnType<Context['agent']>,
    path: string,
  ): Context {
    return {
      environment: { env: { PATH: path }, home: dir },
      configFile: join(dir, 'config.json'),
      runCli: () => Promise.reject(new Error('not used')),
      runs: { start: () => Promise.reject(new Error('not used')), stop: () => undefined },
      agent,
    }
  }

  async function pathWithSkill(): Promise<string> {
    const pkg = join(dir, 'pkg')
    await mkdir(join(pkg, 'bin'), { recursive: true })
    await mkdir(join(pkg, 'skills', 'synapse-pipeline'), { recursive: true })
    await writeFile(join(pkg, 'bin', 'synapse-pipeline'), '')
    await writeFile(join(pkg, 'skills', 'synapse-pipeline', 'SKILL.md'), SKILL)
    return join(pkg, 'bin')
  }

  it('asks the harness named, else the default harness, else Claude', async () => {
    const path = await pathWithSkill()
    const harnesses: string[] = []
    const context = contextWith((run) => {
      harnesses.push(run.harness)
      return Promise.resolve({ code: 0, stdout: 'Agent A [Prompt => "x"];', stderr: '' })
    }, path)
    await handleCall('generateDefinition', request, context)
    await handleCall('setConfig', { patch: { defaultHarness: 'Codex' } }, context)
    await handleCall('generateDefinition', request, context)
    await handleCall('generateDefinition', { ...request, harness: 'Opencode' }, context)
    expect(harnesses).toEqual(['Claude', 'Codex', 'Opencode'])
  })

  it('gives the agent the variables set in the app', async () => {
    const seen: (Record<string, string> | undefined)[] = []
    const context = contextWith(
      (run) => {
        seen.push(run.env)
        return Promise.resolve({ code: 0, stdout: 'Agent A [Prompt => "x"];', stderr: '' })
      },
      await pathWithSkill(),
    )
    await handleCall('setConfig', { patch: { env: { OPENCODE_X: 'y' } } }, context)
    await handleCall('generateDefinition', request, context)
    expect(seen).toEqual([{ OPENCODE_X: 'y' }])
  })

  it('gives the text the agent wrote', async () => {
    let seen: AgentRun | null = null
    const context = contextWith(
      (run) => {
        seen = run
        return Promise.resolve({ code: 0, stdout: '```\nPipeline P {}\n```', stderr: '' })
      },
      await pathWithSkill(),
    )
    const answer = await handleCall('generateDefinition', request, context)
    expect(answer).toEqual({ text: 'Pipeline P {}\n' })
    expect((seen as AgentRun | null)?.prompt).toContain('Build, then review.')
  })

  it('answers 502 when the agent fails or says nothing', async () => {
    const path = await pathWithSkill()
    for (const result of [
      { code: 1, stdout: '', stderr: 'quota\n' },
      { code: 0, stdout: '  \n', stderr: '' },
    ]) {
      const context = contextWith(() => Promise.resolve(result), path)
      await expect(handleCall('generateDefinition', request, context)).rejects.toMatchObject({
        status: 502,
      })
    }
  })

  it('answers 409 when the skill is not there', async () => {
    const context = contextWith(() => Promise.reject(new Error('not used')), dir)
    await expect(handleCall('generateDefinition', request, context)).rejects.toBeInstanceOf(
      CallError,
    )
    await expect(handleCall('generateDefinition', request, context)).rejects.toMatchObject({
      status: 409,
    })
  })

  it('refuses a description that is empty and a name that is not one', async () => {
    const context = contextWith(() => Promise.reject(new Error('not used')), dir)
    for (const bad of [
      { ...request, prompt: '' },
      { ...request, definitions: [{ name: '../x', kind: 'agent' }] },
      { ...request, kind: 'widget' },
    ]) {
      await expect(handleCall('generateDefinition', bad, context)).rejects.toMatchObject({
        status: 400,
      })
    }
  })
})
