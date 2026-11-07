// The world the end-to-end tests run in: a configuration directory with a few
// definitions, a synapse.conf, the app's own settings, the answers a scripted
// run gives, a folder that looks like a vault, and one finished run with a
// transcript. It is made once for a run of the tests, in a directory of its own.

import { spawnSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { delimiter, join } from 'node:path'

export interface World {
  root: string
  // XDG_CONFIG_HOME
  xdg: string
  // Where definitions are, and the skills in it.
  definitions: string
  work: string
  script: string
  conf: string
  vault: string
  // Programs that stand in for the harnesses, found first on PATH.
  bin: string
  // The home and the data folder of the server, so that what is installed on the
  // machine does not matter.
  home: string
  data: string
}

export function worldAt(root: string): World {
  const xdg = join(root, 'xdg')
  return {
    root,
    xdg,
    definitions: join(xdg, 'synapse-pipeline'),
    work: join(root, 'work'),
    script: join(root, 'script.json'),
    conf: join(xdg, 'synapse', 'synapse.conf'),
    vault: join(root, 'vault'),
    bin: join(root, 'bin'),
    home: join(root, 'home'),
    data: join(root, 'data'),
  }
}

const DEFINITIONS: Record<string, string> = {
  'Develop_Feature.synapse': `-- Build a change, then have it reviewed until it is approved.
Pipeline Develop_Feature {
   Develop [Agent => Developer, Harness => Claude, Prompt => "Implement the supplied task."];
   Test    [Agent => Tester, Harness => Claude, Skill => "test-feature"];
   Review  [System => Strict_Reviewer, Harness => Codex];
   Review -> Develop [When => Changes_Requested, Max_Iterations => 5];
}
`,
  'Developer.synapse': `Agent Developer [Prompt => "You are a developer. Implement the change the assignment describes and keep it small."];\n`,
  'Tester.synapse': `Agent Tester [Prompt => "You are a tester. Run the tests and report what fails."];\n`,
  'Reviewer.synapse': `Agent Reviewer [Prompt => "You are a reviewer. Find what is wrong with the change; do not fix it."];\n`,
  'Strict_Reviewer.synapse': `System Strict_Reviewer [Agent => Reviewer, Harness => Codex, Permissions => Read_Only, Skill => "review-code"];\n`,
  'Fixture_Run.synapse': `Pipeline Fixture_Run {
   Work [Harness => Claude, Prompt => "Read notes.txt, write result.txt and list the folder."];
}
`,
}

const SKILLS: Record<string, string> = {
  'review-code': `---
name: review-code
description: Review a change for correctness, edge cases and clarity without changing it.
---

Read the change and list what is wrong with it. Do not edit any file.
`,
  'test-feature': `---
name: test-feature
description: Run the tests for a feature and report which ones fail.
---

Run the project's tests for the change and report which fail.
`,
}

// What each step answers, in order. The pauses are short, so that a run is over
// in a few seconds.
const ANSWERS = {
  Develop: [
    { outcome: 'Done', summary: 'implemented', data: {}, delay_seconds: 0.3 },
    { outcome: 'Done', summary: 'fixed the notes', data: {}, delay_seconds: 0.3 },
  ],
  Test: [
    { outcome: 'Done', summary: 'tests pass', data: {}, delay_seconds: 0.3 },
    { outcome: 'Done', summary: 'tests pass', data: {}, delay_seconds: 0.3 },
  ],
  Review: [
    { outcome: 'Changes_Requested', summary: 'one issue', data: {}, delay_seconds: 0.3 },
    { outcome: 'Approved', summary: 'looks good', data: {}, delay_seconds: 0.3 },
  ],
  Work: [{ outcome: 'Done', summary: 'worked', data: {}, delay_seconds: 0.1 }],
}

function write(path: string, text: string): void {
  mkdirSync(join(path, '..'), { recursive: true })
  writeFileSync(path, text)
}

// A session of Claude that reads a file, writes another and lists the folder,
// in the form `claude --output-format stream-json` writes.
function claudeTranscript(folder: string): string {
  const events = [
    { type: 'system', subtype: 'init' },
    {
      type: 'assistant',
      message: {
        content: [
          { type: 'tool_use', id: 't1', name: 'Read', input: { file_path: `${folder}/notes.txt` } },
        ],
      },
    },
    {
      type: 'user',
      message: { content: [{ type: 'tool_result', tool_use_id: 't1', content: '1\tpineapple' }] },
    },
    {
      type: 'assistant',
      message: {
        content: [
          {
            type: 'tool_use',
            id: 't2',
            name: 'Write',
            input: { file_path: `${folder}/result.txt`, content: 'pineapple\n' },
          },
          { type: 'tool_use', id: 't3', name: 'Bash', input: { command: 'ls' } },
        ],
      },
    },
    {
      type: 'user',
      message: { content: [{ type: 'tool_result', tool_use_id: 't2', content: 'created' }] },
      tool_use_result: { type: 'create', content: 'pineapple\n', structuredPatch: [] },
    },
    {
      type: 'user',
      message: {
        content: [{ type: 'tool_result', tool_use_id: 't3', content: 'notes.txt result.txt' }],
      },
    },
    { type: 'assistant', message: { content: [{ type: 'text', text: 'Wrote the word.' }] } },
    {
      type: 'result',
      is_error: false,
      num_turns: 3,
      duration_ms: 5000,
      total_cost_usd: 0.12,
      usage: {
        input_tokens: 10,
        cache_creation_input_tokens: 100,
        cache_read_input_tokens: 5,
        output_tokens: 40,
      },
    },
  ]
  return events.map((e) => JSON.stringify(e)).join('\n') + '\n'
}

export function environmentFor(world: World, binDirs: readonly string[]): NodeJS.ProcessEnv {
  return {
    ...process.env,
    PATH: [world.bin, ...binDirs, process.env.PATH ?? ''].join(delimiter),
    XDG_CONFIG_HOME: world.xdg,
    SYNAPSE_PIPELINE_RUNNER: 'scripted',
    SYNAPSE_PIPELINE_SCRIPT: world.script,
    // Nothing the tests do may reach a vault, a work directory or a definition
    // directory that is not theirs.
    SYNAPSE_VAULT_DIR: '',
    SYNAPSE_WORK_DIR: world.work,
    SYNAPSE_PIPELINE_PATH: '',
  }
}

// The settings as the world begins: what synapse.conf says and what the app has
// kept. A test that changes either starts from this.
export function resetSettings(world: World): void {
  write(world.conf, '# the settings of the tests\nSYNAPSE_VAULT_PUSH_EVERY=7\n')
  write(
    join(world.xdg, 'synapse-desktop', 'config.json'),
    JSON.stringify({
      workDir: world.work,
      definitionPaths: [],
      defaultHarness: null,
      env: {},
      recentVaults: [],
      terminalFolder: null,
    }),
  )
}

// A harness that prints what it was started with, writes a session file in the
// form of the real one, and then echoes each line that is typed, until the line
// `quit`, which ends it with code 7.
const STUB = [
  '#!/bin/sh',
  'name=$(basename "$0")',
  'echo "STUB $name args: $*"',
  'echo "CODEX_HOME=${CODEX_HOME:-} OPENCODE_CONFIG_DIR=${OPENCODE_CONFIG_DIR:-} CONTENT_ROOT=${SYNAPSE_CONTENT_ROOT:-}"',
  'echo "cwd: $(pwd)"',
  // A headless run, as the app starts one to write a note: the prompt is on standard
  // input, or the last argument for OpenCode; the note is made with the synapse
  // program and its path is the last line.
  'headless=""',
  '[ "$name" = claude ] && [ "$1" = "-p" ] && headless=stdin',
  '[ "$name" = codex ] && [ "$1" = exec ] && headless=stdin',
  '[ "$name" = opencode ] && [ "$1" = run ] && headless=argument',
  'if [ -n "$headless" ]; then',
  '  if [ "$headless" = stdin ]; then prompt=$(cat); else for a in "$@"; do prompt=$a; done; fi',
  '  case "$prompt" in',
  '    *FAILCASE*) echo "FAILED: the stub was asked to fail"; exit 0 ;;',
  '  esac',
  `  printf '%s\\n' "# Stub note" "" "Written by $name" "$prompt" | synapse vault-write "research/Stub note.md"`,
  '  echo "research/Stub note.md"; exit 0',
  'fi',
  'sid=""; prev=""',
  'for a in "$@"; do [ "$prev" = "--session-id" ] && sid="$a"; prev="$a"; done',
  'if [ "$name" = claude ] && [ -n "$sid" ]; then',
  '  d="$HOME/.claude/projects/-stub"; mkdir -p "$d"; f="$d/$sid.jsonl"',
  `  printf '%s\\n' '{"type":"permission-mode"}' >> "$f"`,
  `  printf '%s\\n' '{"type":"user","message":{"role":"user","content":"Fix the bug in a.txt"}}' >> "$f"`,
  `  printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"I will look at the folder."}]}}' >> "$f"`,
  `  printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}]}}' >> "$f"`,
  `  printf '%s\\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"total 8 a.txt"}]}}' >> "$f"`,
  'fi',
  'if [ "$name" = codex ]; then',
  '  d="${CODEX_HOME:-$HOME/.codex}/sessions/$(date +%Y/%m/%d)"; mkdir -p "$d"; f="$d/rollout-stub-$$.jsonl"',
  `  printf '{"type":"session_meta","payload":{"cwd":"%s"}}\\n' "$(pwd)" > "$f"`,
  `  printf '%s\\n' '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a test"}]}}' >> "$f"`,
  `  printf '%s\\n' '{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"echo hello-codex\\"]}","call_id":"c1"}}' >> "$f"`,
  `  printf '%s\\n' '{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"hello-codex"}}' >> "$f"`,
  `  printf '%s\\n' '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Added it."}]}}' >> "$f"`,
  'fi',
  'while IFS= read -r line; do',
  '  echo "typed: $line"',
  '  [ "$line" = quit ] && exit 7',
  'done',
  '',
].join('\n')

export function buildWorld(root: string, binDirs: readonly string[]): World {
  const world = worldAt(root)
  mkdirSync(world.home, { recursive: true })
  mkdirSync(world.data, { recursive: true })
  mkdirSync(world.bin, { recursive: true })
  for (const name of ['claude', 'codex', 'opencode']) {
    writeFileSync(join(world.bin, name), STUB, { mode: 0o755, flag: 'w' })
  }
  for (const [name, text] of Object.entries(DEFINITIONS)) write(join(world.definitions, name), text)
  for (const [name, text] of Object.entries(SKILLS)) {
    write(join(world.definitions, 'skills', name, 'SKILL.md'), text)
  }
  write(world.script, JSON.stringify(ANSWERS, null, 2))
  resetSettings(world)
  mkdirSync(world.work, { recursive: true })

  // A folder that looks like a vault: an index, three notes, git and Obsidian
  // folders that hold no notes.
  write(join(world.vault, 'Index.md'), '# Index\n')
  write(join(world.vault, 'designs', 'a.md'), '# a\n')
  write(join(world.vault, 'tasks', 't.md'), '# t\n')
  mkdirSync(join(world.vault, '.git'), { recursive: true })
  write(join(world.vault, '.obsidian', 'ignored.md'), 'x')

  // The local files of two code graphs in the work directory: one with a node
  // index, made by the program itself, and references, and one with references
  // only.
  const graph = join(world.work, 'widget@main')
  mkdirSync(graph, { recursive: true })
  write(
    join(graph, '_refs.tsv'),
    [
      'Render\tdef\tfunction\tsrc/render.adb:12\tprocedure Render (Scene : Scene_Type) is',
      'Render\tref\tcall\tsrc/main.adb:30\tRender (Current);',
      'Render\tref\tcall\tsrc/loop.adb:8\tRender (Frame.Scene);',
      'Update\tdef\tfunction\tsrc/update.adb:5\tprocedure Update is',
      '',
    ].join('\n'),
  )
  write(join(graph, 'unassigned.txt'), 'scripts/loose.sh\n')
  const built = spawnSync(
    'synapse',
    [
      'index',
      'build',
      '--unassigned',
      join(graph, 'unassigned.txt'),
      '--out',
      join(graph, '_index.bin'),
    ],
    {
      env: environmentFor(world, binDirs),
      encoding: 'utf8',
      input: 'src/render.adb\tRendering\nsrc/main.adb\tRendering\nsrc/update.adb\tGame loop\n',
    },
  )
  if (built.status !== 0) throw new Error(`could not build the index: ${built.stderr}`)
  const thin = join(world.work, 'thin@main')
  mkdirSync(thin, { recursive: true })
  write(join(thin, '_refs.tsv'), 'Only\tdef\tfunction\tsrc/only.adb:1\tprocedure Only is\n')

  // A finished run, made by the program itself, with the transcript that a
  // scripted run does not write put in its record.
  const id = 'exec-fixture1'
  const run = spawnSync('synapse-pipeline', ['run', 'Fixture_Run', '--id', id], {
    env: environmentFor(world, binDirs),
    encoding: 'utf8',
  })
  if (run.status !== 0) {
    throw new Error(`the fixture run failed: ${run.stderr}${run.error ? String(run.error) : ''}`)
  }
  const record = join(world.work, 'pipelines', id)
  const transcript = join(record, 'transcripts', '1-Work-1.jsonl')
  write(transcript, claudeTranscript(join(world.root, 'project')))
  const events = join(record, 'events.jsonl')
  writeFileSync(
    events,
    readFileSync(events, 'utf8').replace(
      '"transcript":null',
      `"transcript":${JSON.stringify(transcript)}`,
    ),
  )
  return world
}
