// Starting a harness with the bundled Synapse loaded for that session only: its
// skills, commands and hooks come from directories of the app's own, which the
// harness is pointed at, and nothing is written into the harness's own
// configuration. A harness that has Synapse installed is used as it is.

import {
  copyFile,
  cp,
  mkdir,
  readdir,
  readFile,
  realpath,
  rm,
  stat,
  symlink,
  writeFile,
} from 'node:fs/promises'
import { basename, delimiter, dirname, join, resolve } from 'node:path'
import type { Harness } from '../shared/transport.ts'

export interface SessionPlan {
  // What to run, and what it is given besides the user's own environment.
  command: string
  args: string[]
  env: Record<string, string>
  // The bundled Synapse is loaded for this session.
  loaded: boolean
  // What is said to the person about it.
  note: string
}

export interface InjectDeps {
  env: Record<string, string | undefined>
  home: string
  // Where the app keeps what it makes for a harness; one folder for each.
  dataDir: string
}

const HOOK_NAME = 'synapse-hook'

const COMMANDS: Record<Harness, string> = {
  Claude: 'claude',
  Codex: 'codex',
  Opencode: 'opencode',
}

const LABELS: Record<Harness, string> = {
  Claude: 'Claude Code',
  Codex: 'Codex',
  Opencode: 'OpenCode',
}

async function isDirectory(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isDirectory() ?? false
}

async function isFile(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isFile() ?? false
}

// The folder with the skills, commands and harness files of the `synapse`
// package: named by SYNAPSE_CONTENT_ROOT, else the package the launcher on PATH
// belongs to, else the one of this checkout.
export async function findContentRoot(
  env: Record<string, string | undefined>,
): Promise<string | null> {
  const candidates: string[] = []
  if (env.SYNAPSE_CONTENT_ROOT) candidates.push(env.SYNAPSE_CONTENT_ROOT)
  const launcher = await findExecutable('synapse', env.PATH ?? '')
  if (launcher !== null) {
    const real = await realpath(launcher).catch(() => null)
    if (real !== null) candidates.push(join(dirname(real), '..'))
  }
  candidates.push(resolve(import.meta.dirname, '..', '..', 'packages', 'synapse'))
  for (const candidate of candidates) {
    if (
      (await isDirectory(join(candidate, 'skills'))) &&
      (await isDirectory(join(candidate, 'harness')))
    ) {
      return resolve(candidate)
    }
  }
  return null
}

// The first file of that name on PATH.
export async function findExecutable(name: string, pathVariable: string): Promise<string | null> {
  const names = process.platform === 'win32' ? [`${name}.exe`, name] : [name]
  for (const dir of pathVariable.split(delimiter).filter(Boolean)) {
    for (const file of names) {
      if (await isFile(join(dir, file))) return join(dir, file)
    }
  }
  return null
}

// Whether the harness has Synapse installed: the hook in the file that
// `synapse-setup configure` writes it to, or the OpenCode plugin it installs.
export async function isInstalled(harness: Harness, home: string): Promise<boolean> {
  const mentionsHook = async (file: string) =>
    (await readFile(file, 'utf8').catch(() => '')).includes(HOOK_NAME)
  switch (harness) {
    case 'Claude':
      return mentionsHook(join(home, '.claude', 'settings.json'))
    case 'Codex':
      return mentionsHook(join(home, '.codex', 'hooks.json'))
    case 'Opencode':
      return isFile(join(home, '.config', 'opencode', 'plugin', 'synapse.js'))
  }
}

// A hooks template with the bare `synapse-hook` at the start of each command
// replaced by where the program is.
export async function renderHooks(
  templatePath: string,
  hookBinary: string,
): Promise<{ hooks: Record<string, unknown> }> {
  const template = JSON.parse(await readFile(templatePath, 'utf8')) as {
    hooks: Record<string, { hooks: { command: string }[] }[]>
  }
  for (const groups of Object.values(template.hooks)) {
    for (const group of groups) {
      for (const hook of group.hooks) {
        if (hook.command.startsWith(`${HOOK_NAME} `)) {
          hook.command = shellWord(slashed(hookBinary)) + hook.command.slice(HOOK_NAME.length)
        }
      }
    }
  }
  return template
}

// What a shell would split or read in a path: a space, a quote, an escape or any
// of the characters it gives a meaning to. A `~` is only read at the start of a
// word and a path is absolute, so a short Windows name such as `RUNNER~1` is not
// quoted.
const NEEDS_QUOTING = /[\s'"\\$`&;|<>()*?[\]{}!#^%]/

// A path as the first word of a shell command: as it is when nothing in it needs
// quoting, else in double quotes with `\`, `"`, `$` and the backtick escaped.
export function shellWord(path: string): string {
  if (!NEEDS_QUOTING.test(path)) return path
  return `"${path.replace(/[\\"$`]/g, '\\$&')}"`
}

// `/` between the parts on Windows: the command runs through a shell that may
// read `\` as an escape.
function slashed(path: string): string {
  return process.platform === 'win32' ? path.replaceAll('\\', '/') : path
}

// Empties a folder of the app's own, which must be inside its data directory.
async function resetDir(dataDir: string, dir: string): Promise<void> {
  if (!dir.startsWith(join(dataDir, '') + (dataDir.endsWith('/') ? '' : '/'))) {
    throw new Error(`${dir} is not inside ${dataDir}`)
  }
  await rm(dir, { recursive: true, force: true })
  await mkdir(dir, { recursive: true })
}

async function skillNames(root: string): Promise<string[]> {
  const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
  return entries.filter((e) => e.isDirectory()).map((e) => e.name)
}

// Every skill of `from` as `<to>/<name>/SKILL.md`.
async function copySkills(from: string, to: string): Promise<void> {
  for (const name of await skillNames(from)) {
    await mkdir(join(to, name), { recursive: true })
    await copyFile(join(from, name, 'SKILL.md'), join(to, name, 'SKILL.md'))
  }
}

async function copyCommands(from: string, to: string): Promise<void> {
  await mkdir(to, { recursive: true })
  for (const file of await readdir(from)) {
    if (file.endsWith('.md')) await copyFile(join(from, file), join(to, file))
  }
}

async function claudeSession(
  dir: string,
  root: string,
  hookBinary: string | null,
  dataDir: string,
) {
  const overlay = join(dir, 'overlay')
  await resetDir(dataDir, overlay)
  await copySkills(join(root, 'skills'), join(overlay, '.claude', 'skills'))
  await copyCommands(join(root, 'commands'), join(overlay, '.claude', 'commands'))
  const settings: Record<string, unknown> = { env: { SYNAPSE_CONTENT_ROOT: root } }
  if (hookBinary !== null) {
    settings.hooks = (
      await renderHooks(join(root, 'harness', 'claude', 'hooks.json'), hookBinary)
    ).hooks
  }
  const settingsFile = join(dir, 'settings.json')
  await writeFile(settingsFile, JSON.stringify(settings, null, 2) + '\n')
  return {
    args: ['--add-dir', overlay, '--settings', settingsFile],
    env: { SYNAPSE_CONTENT_ROOT: root },
  }
}

// The trust a person gave this home's hooks, which the new config keeps.
function trustBlocks(config: string, hooksFile: string): string {
  const blocks = config.match(/^\[hooks\.state\."[^"\n]*"\]\n(?:(?!\[)[^\n]*\n?)*/gm) ?? []
  return blocks.filter((block) => block.startsWith(`[hooks.state."${hooksFile}:`)).join('')
}

async function codexSession(
  dir: string,
  root: string,
  hookBinary: string | null,
  deps: InjectDeps,
) {
  await mkdir(dir, { recursive: true })
  const real = join(deps.home, '.codex')
  // The login of the user's own Codex.
  const auth = join(dir, 'auth.json')
  await rm(auth, { force: true })
  if (await isFile(join(real, 'auth.json'))) await symlink(join(real, 'auth.json'), auth)

  // The user's settings, with the trust given to this home's hooks as it was.
  const hooksFile = join(dir, 'hooks.json')
  const before = await readFile(join(dir, 'config.toml'), 'utf8').catch(() => '')
  const users = await readFile(join(real, 'config.toml'), 'utf8').catch(() => '')
  const kept = trustBlocks(before, hooksFile)
  await writeFile(
    join(dir, 'config.toml'),
    users + (users.endsWith('\n') || users === '' ? '' : '\n') + (kept === '' ? '' : `\n${kept}`),
  )

  const skills = join(dir, 'skills')
  await resetDir(deps.dataDir, skills)
  await copySkills(join(root, 'skills'), skills)
  for (const name of await skillNames(join(root, 'harness', 'codex', 'skills'))) {
    await cp(join(root, 'harness', 'codex', 'skills', name), join(skills, name), {
      recursive: true,
    })
  }
  if (hookBinary !== null) {
    const hooks = await renderHooks(join(root, 'harness', 'codex', 'hooks.json'), hookBinary)
    await writeFile(hooksFile, JSON.stringify(hooks, null, 2) + '\n')
  } else {
    await rm(hooksFile, { force: true })
  }
  return { args: [], env: { CODEX_HOME: dir, SYNAPSE_CONTENT_ROOT: root } }
}

async function opencodeSession(
  dir: string,
  root: string,
  hookBinary: string | null,
  dataDir: string,
) {
  for (const sub of ['skill', 'command', 'plugin']) await resetDir(dataDir, join(dir, sub))
  await copySkills(join(root, 'skills'), join(dir, 'skill'))
  // A model is shown skills and not commands, so the instructions the commands carry
  // are skills here too, the ones Codex gets.
  for (const name of await skillNames(join(root, 'harness', 'codex', 'skills'))) {
    await cp(join(root, 'harness', 'codex', 'skills', name), join(dir, 'skill', name), {
      recursive: true,
    })
  }
  await copyCommands(join(root, 'commands'), join(dir, 'command'))
  if (hookBinary !== null) {
    const template = await readFile(
      join(root, 'harness', 'opencode', 'plugin', 'synapse.js'),
      'utf8',
    )
    await writeFile(
      join(dir, 'plugin', 'synapse.js'),
      template.replace('"__SYNAPSE_HOOK_BIN__"', JSON.stringify(slashed(hookBinary))),
    )
  }
  return { args: [], env: { OPENCODE_CONFIG_DIR: dir, SYNAPSE_CONTENT_ROOT: root } }
}

// How to start the harness for one session.
export async function planSession(harness: Harness, deps: InjectDeps): Promise<SessionPlan> {
  const command = COMMANDS[harness]
  const label = LABELS[harness]
  if (await isInstalled(harness, deps.home)) {
    return {
      command,
      args: [],
      env: {},
      loaded: false,
      note: `Synapse is installed in ${label} and is used as it is.`,
    }
  }
  const root = await findContentRoot(deps.env)
  if (root === null) {
    return {
      command,
      args: [],
      env: {},
      loaded: false,
      note: `The Synapse content was not found, so this is ${label} as it is.`,
    }
  }
  const hookBinary = await findExecutable(HOOK_NAME, deps.env.PATH ?? '')
  const dir = join(deps.dataDir, harness.toLowerCase())
  await mkdir(dir, { recursive: true })
  const made =
    harness === 'Claude'
      ? await claudeSession(dir, root, hookBinary, deps.dataDir)
      : harness === 'Codex'
        ? await codexSession(dir, root, hookBinary, deps)
        : await opencodeSession(dir, root, hookBinary, deps.dataDir)
  const hooks = hookBinary === null ? ` Its hooks are not loaded: ${HOOK_NAME} was not found.` : ''
  const trust =
    harness === 'Codex' && hookBinary !== null
      ? ' Codex asks you to trust the hooks the first time.'
      : ''
  return {
    command,
    ...made,
    loaded: true,
    note: `Synapse is loaded for this session only and nothing is installed in ${label}.${hooks}${trust}`,
  }
}

function quoted(text: string): string {
  return `'${text.replaceAll("'", "'\\''")}'`
}

// Escapes backslashes and quotes for a JSON string written by a shell script.
const JSON_ESCAPE = `sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'`

// What a wrapper writes when it starts a session whose conversation is followed:
// one file in the folder SYNAPSE_SESSIONS_DIR names, which the app reads. Claude
// is given a session id of the wrapper's choosing, so that the file is known
// before it exists; a run that continues another session is not followed.
const CLAUDE_TRACKING = `track=""
if [ -n "$SYNAPSE_SESSIONS_DIR" ]; then
  skip=""
  case "$1" in
    mcp|plugin|plugins|config|doctor|update|install|setup-token|migrate-installer|auth|agents|api-key|help) skip=1 ;;
  esac
  case " $* " in
    *" -p "*|*" --print"*|*" -r "*|*" --resume"*|*" -c "*|*" --continue"*|*" --session-id"*|*" --version"*|*" -v "*|*" --help"*|*" -h "*) skip=1 ;;
  esac
  if [ -z "$skip" ]; then
    id=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
    id=$(printf %s "$id" | tr 'A-Z' 'a-z')
    if [ -n "$id" ]; then
      track="--session-id $id"
      cwd=$(pwd | ${JSON_ESCAPE})
      cfg=$(printf %s "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" | ${JSON_ESCAPE})
      mkdir -p "$SYNAPSE_SESSIONS_DIR" 2>/dev/null
      printf '{"harness":"claude","sessionId":"%s","cwd":"%s","configDir":"%s","startedAt":%s000}\\n' "$id" "$cwd" "$cfg" "$(date +%s)" > "$SYNAPSE_SESSIONS_DIR/.claude-$id.tmp" && mv "$SYNAPSE_SESSIONS_DIR/.claude-$id.tmp" "$SYNAPSE_SESSIONS_DIR/claude-$id.json"
    fi
  fi
fi
`

// Codex has no way to be given a session id, so it is found by where and when it
// started. A run that is a command and not a session is not followed.
const CODEX_TRACKING = `if [ -n "$SYNAPSE_SESSIONS_DIR" ]; then
  case "$1" in
    exec|e|review|login|logout|mcp|plugin|app-server|completion|update|doctor|sandbox|debug|apply|features|help|cloud) ;;
    *)
      cwd=$(pwd | ${JSON_ESCAPE})
      home=$(printf %s "\${CODEX_HOME:-$HOME/.codex}" | ${JSON_ESCAPE})
      mkdir -p "$SYNAPSE_SESSIONS_DIR" 2>/dev/null
      printf '{"harness":"codex","cwd":"%s","home":"%s","startedAt":%s000}\\n' "$cwd" "$home" "$(date +%s)" > "$SYNAPSE_SESSIONS_DIR/.codex-$$.tmp" && mv "$SYNAPSE_SESSIONS_DIR/.codex-$$.tmp" "$SYNAPSE_SESSIONS_DIR/codex-$$.json"
      ;;
  esac
fi
`

export type Tracking = 'claude' | 'codex' | null

// A command that starts the next program of that name on PATH, after its own
// folder, with the arguments and variables of a session plan added, and, for a
// harness whose conversation is followed, a note of the run. PATH is the one of
// the shell it is started from, which is not known until then.
export function shimScript(name: string, plan: SessionPlan, tracking: Tracking = null): string {
  const exports = Object.entries(plan.env).map(
    ([key, value]) => `    export ${key}=${quoted(value)}\n`,
  )
  const args = plan.args.map(quoted).join(' ')
  const before = tracking === 'claude' ? CLAUDE_TRACKING : ''
  // Codex notes where it will keep its sessions, which the variables decide.
  const after = tracking === 'codex' ? CODEX_TRACKING.replace(/^/gm, '    ') : ''
  const typed = tracking === 'claude' ? '$track "$@"' : '"$@"'
  return `#!/bin/sh
# Starts the next ${name} on PATH with the bundled Synapse loaded for this session.
${before}self=$(cd "$(dirname "$0")" && pwd)
old=$IFS
IFS=:
for dir in $PATH; do
  [ "$dir" = "$self" ] && continue
  if [ -f "$dir/${name}" ] && [ -x "$dir/${name}" ]; then
    IFS=$old
${exports.join('')}${after}    exec "$dir/${name}" ${args}${args === '' ? '' : ' '}${typed}
  fi
done
IFS=$old
echo "${name}: command not found" >&2
exit 127
`
}

// zsh reads its files from ZDOTDIR. These read the user's own, and then put the
// folder of the commands first on PATH again, whatever the user's files did to it.
const ZSH_FILES = ['.zshenv', '.zprofile', '.zshrc', '.zlogin'] as const

function zshFile(name: (typeof ZSH_FILES)[number]): string {
  const user = `[ -f "$SYNAPSE_USER_ZDOTDIR/${name}" ] && . "$SYNAPSE_USER_ZDOTDIR/${name}"`
  if (name !== '.zshrc') return `${user}\n`
  return `${user}
if [ -n "$SYNAPSE_SHIM_DIR" ]; then
  path=("$SYNAPSE_SHIM_DIR" \${path:#"$SYNAPSE_SHIM_DIR"})
fi
`
}

export interface ShellPlan extends SessionPlan {
  // The programs that start with Synapse loaded.
  wrapped: string[]
}

// How to start the user's login shell. `claude`, `codex` and `opencode` typed
// in it load the bundled Synapse for that run, unless it is installed.
export async function planShell(deps: InjectDeps): Promise<ShellPlan> {
  const shell = deps.env.SHELL || (process.platform === 'darwin' ? '/bin/zsh' : '/bin/sh')
  const plain = (note: string): ShellPlan => ({
    command: shell,
    args: ['-l'],
    env: {},
    loaded: false,
    note,
    wrapped: [],
  })
  if (process.platform === 'win32') return plain('Your shell.')

  const wrapped: { name: string; plan: SessionPlan; tracking: Tracking }[] = []
  for (const harness of ['Claude', 'Codex', 'Opencode'] as const) {
    const plan = await planSession(harness, deps)
    // Claude and Codex are wrapped to follow their conversations, whether or not
    // Synapse is loaded into them.
    const tracking: Tracking =
      harness === 'Claude' ? 'claude' : harness === 'Codex' ? 'codex' : null
    if (plan.loaded || tracking !== null) wrapped.push({ name: plan.command, plan, tracking })
  }
  if (wrapped.length === 0) return plain('Your login shell.')

  const shims = join(deps.dataDir, 'shims')
  await resetDir(deps.dataDir, shims)
  for (const { name, plan, tracking } of wrapped) {
    await writeFile(join(shims, name), shimScript(name, plan, tracking), { mode: 0o755 })
  }
  const env: Record<string, string> = {
    PATH: [shims, deps.env.PATH ?? ''].filter(Boolean).join(delimiter),
    SYNAPSE_SHIM_DIR: shims,
  }
  if (basename(shell) === 'zsh') {
    const zdotdir = join(deps.dataDir, 'zdotdir')
    await resetDir(deps.dataDir, zdotdir)
    for (const name of ZSH_FILES) await writeFile(join(zdotdir, name), zshFile(name))
    env.SYNAPSE_USER_ZDOTDIR = deps.env.ZDOTDIR || deps.home
    env.ZDOTDIR = zdotdir
  }
  const names = wrapped.filter((w) => w.plan.loaded).map((w) => w.name)
  const followed = wrapped.filter((w) => w.tracking !== null).map((w) => w.name)
  const loads =
    names.length === 0
      ? ''
      : ` ${names.join(', ')} started here load Synapse for that run only and nothing is installed.`
  return {
    command: shell,
    args: ['-l'],
    env,
    loaded: names.length > 0,
    note: `Your login shell.${loads} The conversation of a ${followed.join(' or ')} started here shows below the terminal.`,
    wrapped: names,
  }
}
