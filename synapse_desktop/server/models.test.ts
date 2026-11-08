import { beforeEach, describe, expect, it } from 'vitest'
import { modelSchema } from '../shared/calls.ts'
import {
  claudeCatalog,
  codexCatalog,
  connectedProviders,
  forgetModels,
  listModels,
  opencodeCatalog,
  parseClaudeModels,
  parseOpencodeModels,
  type RunProgram,
} from './models.ts'

const MODELS = [
  'opencode/glm-5.3-flash-free',
  'openrouter/z-ai/glm-5.3-flash',
  'openrouter/~z-ai/glm-flash-latest',
  'anthropic/claude-sonnet',
].join('\n')

const AUTH = '\u001b[1mOpenRouter\u001b[0m  API key  stored\n'

beforeEach(() => forgetModels())

describe('the models OpenCode lists', () => {
  it('are a line each, provider and model, without colours, blank lines or repeats', () => {
    expect(
      parseOpencodeModels(
        `\u001b[2mopencode/a\u001b[0m\n\nopenrouter/x/y\nopencode/a\nnot a model\nnoprovider\n/lead\ntrail/\n`,
      ),
    ).toEqual([
      { id: 'opencode/a', provider: 'opencode' },
      { id: 'openrouter/x/y', provider: 'openrouter' },
    ])
  })

  it('keep the characters models are named with, such as a tilde', () => {
    expect(parseOpencodeModels('openrouter/~z-ai/glm-flash-latest\n')[0]?.id).toBe(
      'openrouter/~z-ai/glm-flash-latest',
    )
  })
})

describe('the providers OpenCode is connected to', () => {
  it('are the names at the start of the lines of its list, as they are named in the models', () => {
    expect(connectedProviders(AUTH)).toEqual(new Set(['openrouter']))
    expect(
      connectedProviders('OpenCode Zen  OAuth  stored\nGitHub Copilot  OAuth  stored\n'),
    ).toEqual(new Set(['opencodezen', 'githubcopilot']))
  })

  it('are none for an empty list', () => {
    expect(connectedProviders('')).toEqual(new Set())
  })
})

describe('the catalog of OpenCode', () => {
  it('has the models of connected providers, and its own, as available, first', () => {
    const { models, note } = opencodeCatalog(MODELS, AUTH)
    expect(models.map((m) => [m.id, m.available])).toEqual([
      ['opencode/glm-5.3-flash-free', true],
      ['openrouter/z-ai/glm-5.3-flash', true],
      ['openrouter/~z-ai/glm-flash-latest', true],
      ['anthropic/claude-sonnet', false],
    ])
    expect(note).toBe(
      '3 of the 4 models are of providers that are connected; the others need a login first.',
    )
  })

  it('says nothing of providers when every model can be used', () => {
    expect(opencodeCatalog('opencode/a\n', '').note).toBeNull()
  })

  it('says when there is nothing listed', () => {
    expect(opencodeCatalog('', AUTH)).toEqual({ models: [], note: 'OpenCode listed no models.' })
  })
})

describe('listing the models of a harness', () => {
  const answering =
    (models: string, auth: string, calls: string[] = []): RunProgram =>
    async (program, args) => {
      calls.push(`${program} ${args.join(' ')}`)
      return args[0] === 'models' ? { code: 0, stdout: models } : { code: 0, stdout: auth }
    }

  it('asks OpenCode for its models and its providers, by the PATH of the login shell', async () => {
    const calls: string[] = []
    const seen: (string | undefined)[] = []
    const run: RunProgram = async (program, args, env) => {
      seen.push(env.PATH)
      return answering(MODELS, AUTH, calls)(program, args, env)
    }
    const catalog = await listModels('Opencode', {
      run,
      env: { PATH: '/own' },
      loginPath: async () => '/login',
    })
    expect(catalog.models).toHaveLength(4)
    expect(calls.sort()).toEqual(['opencode auth list', 'opencode models'])
    expect(seen).toEqual(['/login:/own', '/login:/own'])
  })

  it('keeps the answer, so that the long list is printed once', async () => {
    const calls: string[] = []
    const run = answering(MODELS, AUTH, calls)
    const deps = { run, env: {}, loginPath: async () => null }
    await listModels('Opencode', deps)
    await listModels('Opencode', deps)
    expect(calls).toHaveLength(2)
    forgetModels()
    await listModels('Opencode', deps)
    expect(calls).toHaveLength(4)
  })

  it('has none, and says so, when OpenCode cannot list them, and does not keep that', async () => {
    const failing: RunProgram = async () => ({ code: 127, stdout: '' })
    const catalog = await listModels('Opencode', {
      run: failing,
      env: {},
      loginPath: async () => null,
    })
    expect(catalog).toEqual({
      models: [],
      note: 'OpenCode could not list its models. Type a name instead.',
    })
    const working = await listModels('Opencode', {
      run: answering(MODELS, AUTH),
      env: {},
      loginPath: async () => null,
    })
    expect(working.models).toHaveLength(4)
  })

  it('lists them all when the list of providers cannot be had', async () => {
    const run: RunProgram = async (_p, args) =>
      args[0] === 'models' ? { code: 0, stdout: MODELS } : { code: 1, stdout: '' }
    const catalog = await listModels('Opencode', { run, env: {}, loginPath: async () => null })
    expect(catalog.models.filter((m) => m.available).map((m) => m.provider)).toEqual(['opencode'])
  })
})

describe('the name of a model', () => {
  it('holds what the names of models are made of', () => {
    for (const name of [
      'sonnet',
      'gpt-5.6-terra',
      'opencode/glm-5.3-flash-free',
      'openrouter/z-ai/glm-5.3-flash',
      'openrouter/~z-ai/glm-flash-latest',
      'anthropic/claude-3.5:beta',
      'sonnet[1m]',
    ]) {
      expect(modelSchema.safeParse(name).success, name).toBe(true)
    }
  })

  it('cannot be taken for a flag, and holds no space, quote or shell character', () => {
    for (const name of [
      '--dangerously-skip-permissions',
      '-m',
      ' sonnet',
      'a b',
      'a;b',
      '[1m]',
      'a"b',
      '$(x)',
      '',
      'x'.repeat(201),
    ]) {
      expect(modelSchema.safeParse(name).success, name).toBe(false)
    }
  })
})

// What `claude -p /model` answers, which takes no model to answer.
const CLAUDE_ANSWER =
  'Current model: `Sonnet 5.5`\nUsage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID.\n'

// What `codex debug models` renders, cut to what is read of it.
const CODEX_ANSWER = JSON.stringify({
  models: [
    {
      slug: 'gpt-b',
      display_name: 'GPT B',
      description: 'Second.',
      visibility: 'list',
      priority: 2,
    },
    {
      slug: 'gpt-a',
      display_name: 'GPT A',
      description: 'First.',
      visibility: 'list',
      priority: 1,
    },
    {
      slug: 'gpt-old',
      display_name: 'GPT Old',
      description: 'Old.',
      visibility: 'hide',
      priority: 3,
    },
    { slug: 'bad name', display_name: 'Bad', visibility: 'list', priority: 4 },
    { slug: 'gpt-c', visibility: 'list', priority: 5 },
  ],
})

describe('the aliases of Claude Code', () => {
  it('are the names its /model command says it takes, and the model it is on', () => {
    expect(parseClaudeModels(CLAUDE_ANSWER)).toEqual({
      current: 'Sonnet 5.5',
      names: [
        'sonnet',
        'opus',
        'haiku',
        'fable',
        'best',
        'sonnet[1m]',
        'opus[1m]',
        'fable[1m]',
        'opusplan',
        'default',
      ],
    })
  })

  it('are none from an answer that does not list them', () => {
    expect(parseClaudeModels('Unknown command: /model')).toEqual({ current: null, names: [] })
    expect(parseClaudeModels('')).toEqual({ current: null, names: [] })
  })

  it('are a catalog that names the model it is on and says a full ID can be typed', () => {
    const catalog = claudeCatalog(CLAUDE_ANSWER)
    expect(catalog.models.map((m) => m.id)).toContain('sonnet[1m]')
    expect(catalog.models.every((m) => m.available && m.provider === null)).toBe(true)
    expect(catalog.note).toBe('It is on Sonnet 5.5 now. Any full model ID can be typed as well.')
  })
})

describe('the models Codex lists', () => {
  it('are those it shows, in its own order, each with what it says of it', () => {
    const { models, note } = codexCatalog(CODEX_ANSWER)
    expect(models.map((m) => m.id)).toEqual(['gpt-a', 'gpt-b', 'gpt-c'])
    expect(models[0]?.detail).toBe('GPT A: First.')
    expect(models[2]?.detail).toBeNull()
    expect(note).toBe('Any model name can be typed as well.')
  })

  it('are none from what is not the catalog', () => {
    expect(codexCatalog('not json').models).toEqual([])
    expect(codexCatalog('{"other": 1}').models).toEqual([])
    expect(codexCatalog('{"models": []}').models).toEqual([])
  })
})

describe('listing the models of Claude Code and Codex', () => {
  it('asks Claude Code its /model, with no session kept, and Codex for its catalogue', async () => {
    const calls: string[] = []
    const run: RunProgram = async (program, args) => {
      calls.push(`${program} ${args.join(' ')}`)
      return { code: 0, stdout: program === 'claude' ? CLAUDE_ANSWER : CODEX_ANSWER }
    }
    const deps = { run, env: {}, loginPath: async () => null }
    const claude = await listModels('Claude', deps)
    const codex = await listModels('Codex', deps)
    expect(calls).toEqual(['claude -p /model --no-session-persistence', 'codex debug models'])
    expect(claude.models).toHaveLength(10)
    expect(codex.models).toHaveLength(3)
  })

  it('keeps each harness list on its own', async () => {
    let calls = 0
    const run: RunProgram = async () => {
      calls += 1
      return { code: 0, stdout: CLAUDE_ANSWER }
    }
    const deps = { run, env: {}, loginPath: async () => null }
    await listModels('Claude', deps)
    await listModels('Claude', deps)
    expect(calls).toBe(1)
    const codex: RunProgram = async () => ({ code: 0, stdout: CODEX_ANSWER })
    expect((await listModels('Codex', { ...deps, run: codex })).models).toHaveLength(3)
  })

  it('says what to do when one cannot be had, and does not keep that', async () => {
    const failing: RunProgram = async () => ({ code: 127, stdout: '' })
    const deps = { env: {}, loginPath: async () => null }
    expect(await listModels('Claude', { ...deps, run: failing })).toEqual({
      models: [],
      note: 'Claude Code could not list its models. Type a name instead.',
    })
    expect((await listModels('Codex', { ...deps, run: failing })).note).toContain(
      'Codex could not list its models.',
    )
    const working: RunProgram = async () => ({ code: 0, stdout: CLAUDE_ANSWER })
    expect((await listModels('Claude', { ...deps, run: working })).models).toHaveLength(10)
  })
})
