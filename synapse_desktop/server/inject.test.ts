import { mkdir, mkdtemp, readFile, readdir, readlink, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { spawnSync } from 'node:child_process'
import { chmod } from 'node:fs/promises'
import { delimiter } from 'node:path'
import {
  findContentRoot,
  findExecutable,
  isInstalled,
  planSession,
  planShell,
  renderHooks,
  shellWord,
  shimScript,
  type InjectDeps,
} from './inject.ts'

let dir: string
let deps: InjectDeps
let pkg: string
let hook: string

async function put(path: string, text: string): Promise<void> {
  await mkdir(join(path, '..'), { recursive: true })
  await writeFile(path, text)
}

const HOOKS = JSON.stringify({
  hooks: {
    SessionStart: [
      { hooks: [{ type: 'command', command: 'synapse-hook session-start' }] },
      { hooks: [{ type: 'command', command: 'echo not-ours' }] },
    ],
  },
})

// A package like the `synapse` one: skills, commands and a file for each harness.
async function makePackage(root: string): Promise<void> {
  await put(join(root, 'skills', 'query', 'SKILL.md'), '---\nname: query\n---\n')
  await put(join(root, 'skills', 'vault', 'SKILL.md'), '---\nname: vault\n---\n')
  await put(join(root, 'commands', 'note.md'), 'note command\n')
  await put(join(root, 'commands', 'notes.txt'), 'not a command\n')
  await put(join(root, 'harness', 'claude', 'hooks.json'), HOOKS)
  await put(join(root, 'harness', 'codex', 'hooks.json'), HOOKS)
  await put(join(root, 'harness', 'codex', 'skills', 'codex-only', 'SKILL.md'), 'codex skill\n')
  await put(
    join(root, 'harness', 'opencode', 'plugin', 'synapse.js'),
    'const bin = "__SYNAPSE_HOOK_BIN__"\n',
  )
}

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-inject-'))
  pkg = join(dir, 'pkg')
  await makePackage(pkg)
  hook = join(dir, 'bin', 'synapse-hook')
  await put(hook, '#!/bin/sh\n')
  deps = {
    env: { SYNAPSE_CONTENT_ROOT: pkg, PATH: join(dir, 'bin') },
    home: join(dir, 'home'),
    dataDir: join(dir, 'data'),
  }
  await mkdir(deps.home, { recursive: true })
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('finding the content and the hook', () => {
  it('uses the folder SYNAPSE_CONTENT_ROOT names, and the package of the launcher on PATH', async () => {
    expect(await findContentRoot({ SYNAPSE_CONTENT_ROOT: pkg })).toBe(pkg)
    // A launcher in `<package>/bin`, as npm makes it.
    await put(join(pkg, 'bin', 'synapse'), '#!/bin/sh\n')
    expect(await findContentRoot({ PATH: join(pkg, 'bin') })).toBe(pkg)
  })

  it('finds a program on PATH, and nothing when it is not there', async () => {
    expect(await findExecutable('synapse-hook', join(dir, 'bin'))).toBe(hook)
    expect(await findExecutable('synapse-hook', join(dir, 'nowhere'))).toBeNull()
  })

  it('puts where the hook is in front of the commands that name it', async () => {
    const rendered = await renderHooks(join(pkg, 'harness', 'claude', 'hooks.json'), hook)
    const commands = JSON.stringify(rendered)
    expect(commands).toContain(`${hook} session-start`)
    expect(commands).toContain('echo not-ours')
  })

  it('quotes a hook path that has a blank in it, as one word, and leaves other paths as they are', async () => {
    const spaced = join(pkg, 'Synapse Desktop.app', 'synapse-hook')
    const rendered = JSON.stringify(
      await renderHooks(join(pkg, 'harness', 'claude', 'hooks.json'), spaced),
    )
    expect(rendered).toContain(`\\"${spaced}\\" session-start`)
    expect(shellWord('/usr/local/bin/synapse-hook')).toBe('/usr/local/bin/synapse-hook')
    expect(shellWord('C:/Program Files/Synapse/synapse-hook.exe')).toBe(
      '"C:/Program Files/Synapse/synapse-hook.exe"',
    )
    expect(shellWord('/a/it"s $HOME/h')).toBe('"/a/it\\"s \\$HOME/h"')
  })
})

describe('isInstalled', () => {
  it('knows Synapse by its hook in the file that configure writes, and by the plugin', async () => {
    expect(await isInstalled('Claude', deps.home)).toBe(false)
    expect(await isInstalled('Codex', deps.home)).toBe(false)
    expect(await isInstalled('Opencode', deps.home)).toBe(false)
    await put(
      join(deps.home, '.claude', 'settings.json'),
      '{"hooks":{"x":"/bin/synapse-hook start"}}',
    )
    await put(join(deps.home, '.codex', 'hooks.json'), '{"hooks":{}}')
    await put(join(deps.home, '.config', 'opencode', 'plugin', 'synapse.js'), '')
    expect(await isInstalled('Claude', deps.home)).toBe(true)
    expect(await isInstalled('Codex', deps.home)).toBe(false)
    expect(await isInstalled('Opencode', deps.home)).toBe(true)
  })
})

describe('a harness that has Synapse installed', () => {
  it('is started as it is, and nothing is made', async () => {
    await put(join(deps.home, '.claude', 'settings.json'), '{"hooks":{"x":"synapse-hook start"}}')
    const plan = await planSession('Claude', deps)
    expect(plan).toMatchObject({ command: 'claude', args: [], env: {}, loaded: false })
    expect(plan.note).toContain('installed in Claude Code')
    expect(await stat(deps.dataDir).catch(() => null)).toBeNull()
  })
})

describe('Claude Code', () => {
  it('gets skills and commands as an added folder and hooks as a settings file', async () => {
    const plan = await planSession('Claude', deps)
    const overlay = join(deps.dataDir, 'claude', 'overlay')
    const settings = join(deps.dataDir, 'claude', 'settings.json')
    expect(plan.command).toBe('claude')
    expect(plan.args).toEqual(['--add-dir', overlay, '--settings', settings])
    expect(plan.loaded).toBe(true)
    expect(plan.env).toEqual({ SYNAPSE_CONTENT_ROOT: pkg })
    expect((await readdir(join(overlay, '.claude', 'skills'))).sort()).toEqual(['query', 'vault'])
    expect(await readdir(join(overlay, '.claude', 'commands'))).toEqual(['note.md'])
    const written = JSON.parse(await readFile(settings, 'utf8')) as {
      env: Record<string, string>
      hooks: unknown
    }
    expect(written.env.SYNAPSE_CONTENT_ROOT).toBe(pkg)
    expect(JSON.stringify(written.hooks)).toContain(`${hook} session-start`)
  })

  it('leaves out what a skill that has gone left behind', async () => {
    await planSession('Claude', deps)
    await rm(join(pkg, 'skills', 'vault'), { recursive: true })
    await planSession('Claude', deps)
    expect(await readdir(join(deps.dataDir, 'claude', 'overlay', '.claude', 'skills'))).toEqual([
      'query',
    ])
  })

  it('loads no hooks and says so when the hook program is not found', async () => {
    const plan = await planSession('Claude', {
      ...deps,
      env: { SYNAPSE_CONTENT_ROOT: pkg, PATH: '' },
    })
    expect(plan.loaded).toBe(true)
    expect(plan.note).toContain('hooks are not loaded')
    const written = JSON.parse(
      await readFile(join(deps.dataDir, 'claude', 'settings.json'), 'utf8'),
    ) as object
    expect(written).not.toHaveProperty('hooks')
  })
})

describe('Codex', () => {
  const trusted = (home: string) =>
    `[hooks.state."${home}/hooks.json:session_start:0:0"]\ntrusted_hash = "sha256:abc"\n`

  it('gets a home of its own with the login linked, the settings copied and skills and hooks added', async () => {
    await put(join(deps.home, '.codex', 'auth.json'), '{"token":"x"}')
    await put(join(deps.home, '.codex', 'config.toml'), 'model = "m"\n')
    const plan = await planSession('Codex', deps)
    const home = join(deps.dataDir, 'codex')
    expect(plan.args).toEqual([])
    expect(plan.env).toEqual({ CODEX_HOME: home, SYNAPSE_CONTENT_ROOT: pkg })
    expect(await readlink(join(home, 'auth.json'))).toBe(join(deps.home, '.codex', 'auth.json'))
    expect(await readFile(join(home, 'config.toml'), 'utf8')).toBe('model = "m"\n')
    expect((await readdir(join(home, 'skills'))).sort()).toEqual(['codex-only', 'query', 'vault'])
    expect(await readFile(join(home, 'hooks.json'), 'utf8')).toContain(`${hook} session-start`)
    // The user's own home is not touched.
    expect((await readdir(join(deps.home, '.codex'))).sort()).toEqual(['auth.json', 'config.toml'])
    expect(plan.note).toContain('trust the hooks')
  })

  it('keeps the trust given to its hooks when it is started again, and the settings follow the user', async () => {
    await put(join(deps.home, '.codex', 'config.toml'), 'model = "m"\n')
    await planSession('Codex', deps)
    const home = join(deps.dataDir, 'codex')
    const config = await readFile(join(home, 'config.toml'), 'utf8')
    await writeFile(join(home, 'config.toml'), config + '\n' + trusted(home))
    await put(join(deps.home, '.codex', 'config.toml'), 'model = "changed"\n')

    await planSession('Codex', deps)
    const again = await readFile(join(home, 'config.toml'), 'utf8')
    expect(again).toContain('model = "changed"')
    expect(again.split(trusted(home)).length - 1).toBe(1)
    await planSession('Codex', deps)
    expect(
      (await readFile(join(home, 'config.toml'), 'utf8')).split(trusted(home)).length - 1,
    ).toBe(1)
  })

  it('works for a user with no Codex yet', async () => {
    const plan = await planSession('Codex', deps)
    expect(plan.loaded).toBe(true)
    expect(await stat(join(deps.dataDir, 'codex', 'auth.json')).catch(() => null)).toBeNull()
  })
})

describe('OpenCode', () => {
  it('gets a configuration folder with skills, commands and the plugin that has the hook in it', async () => {
    const plan = await planSession('Opencode', deps)
    const config = join(deps.dataDir, 'opencode')
    expect(plan.env).toEqual({ OPENCODE_CONFIG_DIR: config, SYNAPSE_CONTENT_ROOT: pkg })
    expect((await readdir(join(config, 'skill'))).sort()).toEqual(['query', 'vault'])
    expect(await readdir(join(config, 'command'))).toEqual(['note.md'])
    const plugin = await readFile(join(config, 'plugin', 'synapse.js'), 'utf8')
    expect(plugin).toBe(`const bin = ${JSON.stringify(hook)}\n`)
  })

  it('has no plugin without the hook program', async () => {
    await planSession('Opencode', deps)
    await planSession('Opencode', { ...deps, env: { SYNAPSE_CONTENT_ROOT: pkg, PATH: '' } })
    expect(await readdir(join(deps.dataDir, 'opencode', 'plugin'))).toEqual([])
  })
})

const zshAvailable = spawnSync('zsh', ['--version']).status === 0

describe('wrapper commands', () => {
  async function realProgram(folder: string, name: string): Promise<void> {
    const file = join(folder, name)
    await put(file, `#!/bin/sh\necho "REAL ${name} args=$* env=$SYNAPSE_X"\n`)
    await chmod(file, 0o755)
  }

  function run(script: string, path: string, ...args: string[]) {
    // The system folders are on every shell's PATH, after the others.
    return spawnSync('/bin/sh', [script, ...args], {
      env: { PATH: `${path}${delimiter}/usr/bin${delimiter}/bin` },
      encoding: 'utf8',
    })
  }

  it('quotes what it is given, so that a value with a quote or a blank survives', () => {
    const text = shimScript('claude', {
      command: 'claude',
      args: ['--add-dir', "/a b/it's"],
      env: { SYNAPSE_X: "v'1" },
      loaded: true,
      note: '',
    })
    expect(text).toContain("export SYNAPSE_X='v'\\''1'")
    expect(text).toContain(`'--add-dir' '/a b/it'\\''s' "$@"`)
  })

  it('starts the next program of the name on PATH, after its own folder, with the plan first and the typed arguments after', async () => {
    const shims = join(dir, 'shims')
    const real = join(dir, 'real')
    await mkdir(shims, { recursive: true })
    await realProgram(real, 'claude')
    await realProgram(shims, 'claude')
    // The shim stands where the real one would be found first.
    const shim = shimScript('claude', {
      command: 'claude',
      args: ['--injected'],
      env: { SYNAPSE_X: 'one' },
      loaded: true,
      note: '',
    })
    await writeFile(join(shims, 'claude'), shim, { mode: 0o755 })
    const out = run(join(shims, 'claude'), [shims, real].join(delimiter), 'typed', 'args')
    expect(out.status).toBe(0)
    expect(out.stdout).toBe('REAL claude args=--injected typed args env=one\n')
  })

  it('says so, and does not start itself again, when there is no other program of the name', async () => {
    const shims = join(dir, 'shims')
    await mkdir(shims, { recursive: true })
    await writeFile(
      join(shims, 'codex'),
      shimScript('codex', { command: 'codex', args: [], env: {}, loaded: true, note: '' }),
      { mode: 0o755 },
    )
    const out = run(join(shims, 'codex'), shims)
    expect(out.status).toBe(127)
    expect(out.stderr).toContain('codex: command not found')
  })

  it('are made for the harnesses that do not have Synapse installed, and put first on the PATH of a login shell', async () => {
    await put(join(deps.home, '.claude', 'settings.json'), '{"hooks":{"x":"synapse-hook start"}}')
    const plan = await planShell({ ...deps, env: { ...deps.env, SHELL: '/bin/bash' } })
    const shims = join(deps.dataDir, 'shims')
    expect(plan.command).toBe('/bin/bash')
    expect(plan.args).toEqual(['-l'])
    expect(plan.loaded).toBe(true)
    // The ones that load Synapse; Claude is wrapped as well, to be followed.
    expect(plan.wrapped).toEqual(['codex', 'opencode'])
    expect((await readdir(shims)).sort()).toEqual(['claude', 'codex', 'opencode'])
    expect(await readFile(join(shims, 'claude'), 'utf8')).not.toContain('--add-dir')
    expect(plan.env.PATH).toBe(`${shims}${delimiter}${deps.env.PATH}`)
    expect(plan.env.ZDOTDIR).toBeUndefined()
    expect(plan.note).toContain('codex, opencode')
  })

  it('load nothing when every harness has Synapse installed, but still follow Claude and Codex', async () => {
    await put(join(deps.home, '.claude', 'settings.json'), 'synapse-hook')
    await put(join(deps.home, '.codex', 'hooks.json'), 'synapse-hook')
    await put(join(deps.home, '.config', 'opencode', 'plugin', 'synapse.js'), '')
    const plan = await planShell(deps)
    expect(plan).toMatchObject({ loaded: false, wrapped: [] })
    expect((await readdir(join(deps.dataDir, 'shims'))).sort()).toEqual(['claude', 'codex'])
    expect(plan.note).not.toContain('load Synapse')
    expect(plan.note).toContain('claude or codex')
  })

  it.skipIf(!zshAvailable)(
    'keep first place in zsh, whatever the user files do to PATH',
    async () => {
      // A user's .zshrc that puts a program of its own ahead of everything.
      const mine = join(dir, 'mine')
      await realProgram(mine, 'claude')
      await put(join(deps.home, '.zshrc'), `export PATH="${mine}:$PATH"\n`)
      const real = join(dir, 'real')
      await realProgram(real, 'claude')
      const plan = await planShell({
        ...deps,
        env: {
          ...deps.env,
          SHELL: '/bin/zsh',
          PATH: `${deps.env.PATH}${delimiter}${real}:/usr/bin:/bin`,
        },
      })
      expect(plan.env.ZDOTDIR).toBe(join(deps.dataDir, 'zdotdir'))
      const out = spawnSync('zsh', ['-l', '-i', '-c', 'command -v claude; claude one'], {
        env: { ...plan.env, HOME: deps.home },
        encoding: 'utf8',
      })
      expect(out.stdout.split('\n')[0]).toBe(join(deps.dataDir, 'shims', 'claude'))
      expect(out.stdout).toContain('REAL claude args=--add-dir')
      expect(out.stdout).toContain(' one env=')
    },
  )
})

describe('following a conversation', () => {
  let sessions: string
  let shims: string
  let real: string

  beforeEach(async () => {
    sessions = join(dir, 'sessions')
    shims = join(dir, 'shims')
    real = join(dir, 'real')
    await mkdir(shims, { recursive: true })
    for (const name of ['claude', 'codex']) {
      await put(join(real, name), `#!/bin/sh\necho "REAL ${name} $*"\n`)
      await chmod(join(real, name), 0o755)
    }
  })

  async function install(
    name: 'claude' | 'codex',
    plan = { args: [] as string[], env: {} as Record<string, string> },
  ) {
    await writeFile(
      join(shims, name),
      shimScript(name, { command: name, ...plan, loaded: false, note: '' }, name),
      { mode: 0o755 },
    )
  }

  function start(name: string, args: string[], cwd = dir, extra: Record<string, string> = {}) {
    return spawnSync('/bin/sh', [join(shims, name), ...args], {
      cwd,
      env: {
        PATH: `${shims}${delimiter}${real}${delimiter}/usr/bin${delimiter}/bin`,
        HOME: deps.home,
        SYNAPSE_SESSIONS_DIR: sessions,
        ...extra,
      },
      encoding: 'utf8',
    })
  }

  async function registrations(): Promise<Record<string, unknown>[]> {
    const names = (await readdir(sessions).catch(() => [])).filter((n) => n.endsWith('.json'))
    return Promise.all(
      names.map(
        async (n) =>
          JSON.parse(await readFile(join(sessions, n), 'utf8')) as Record<string, unknown>,
      ),
    )
  }

  it('gives a new Claude session an id and says where and when it started', async () => {
    await install('claude')
    const out = start('claude', ['fix it'])
    const id = /--session-id ([0-9a-f-]{36})/.exec(out.stdout)?.[1]
    expect(id).toBeDefined()
    expect(out.stdout).toContain('REAL claude --session-id')
    expect(out.stdout.trim().endsWith('fix it')).toBe(true)
    const [registration] = await registrations()
    expect(registration).toMatchObject({
      harness: 'claude',
      sessionId: id,
      cwd: dir,
      configDir: join(deps.home, '.claude'),
    })
    expect(Math.abs((registration?.startedAt as number) - Date.now())).toBeLessThan(10_000)
  })

  it('writes a folder with a quote or a backslash in its name as valid JSON', async () => {
    await install('claude')
    const odd = join(dir, 'a"b\\c d')
    await mkdir(odd)
    start('claude', [], odd)
    const [registration] = await registrations()
    expect(registration?.cwd).toBe(odd)
  })

  it('does not follow a run that is not a new session, and leaves the arguments as they were', async () => {
    await install('claude')
    for (const args of [
      ['--resume'],
      ['-c'],
      ['--continue'],
      ['-p', 'hi'],
      ['mcp', 'list'],
      ['doctor'],
      ['--version'],
      ['--session-id', 'abc'],
      ['-h'],
    ]) {
      const out = start('claude', args)
      expect(out.stdout.trim()).toBe(`REAL claude ${args.join(' ')}`)
    }
    expect(await registrations()).toEqual([])
  })

  it('follows nothing when it is not asked to, and still starts the program', async () => {
    await install('claude')
    const out = spawnSync('/bin/sh', [join(shims, 'claude'), 'x'], {
      env: { PATH: `${shims}${delimiter}${real}${delimiter}/usr/bin${delimiter}/bin` },
      encoding: 'utf8',
    })
    expect(out.stdout.trim()).toBe('REAL claude x')
  })

  it('notes where and when a Codex session started and where it keeps its sessions', async () => {
    await install('codex', { args: [], env: { CODEX_HOME: '/the/home' } })
    start('codex', ['fix it'])
    const [registration] = await registrations()
    expect(registration).toMatchObject({ harness: 'codex', cwd: dir, home: '/the/home' })
    expect(typeof registration?.startedAt).toBe('number')
  })

  it('does not note a Codex run that is a command and not a session', async () => {
    await install('codex')
    for (const args of [['exec', 'x'], ['login'], ['mcp', 'list'], ['review']]) {
      expect(start('codex', args).status).toBe(0)
    }
    expect(await registrations()).toEqual([])
  })
})
