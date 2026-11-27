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
  // A `synapse-pipeline` launcher with the program's skill beside it, as the npm package has
  // them: the app finds the skill by the launcher on PATH. It is after the built programs on
  // PATH, so it is only where the skill is looked for, never the program that runs.
  pipelinePackage: string
  // The folder the Live_Run pipeline works in: a repository with one commit.
  live: string
  // The folder the finished fixture run worked in: a repository with what the run changed in it.
  project: string
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
    pipelinePackage: join(root, 'pipeline-package'),
    live: join(root, 'live-project'),
    project: join(root, 'project'),
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
  'Live_Run.synapse': `Pipeline Live_Run {
   Work [Harness => Claude, Prompt => "LIVECASE change a.txt, then take your time."];
}
`,
  'Fixture_Run.synapse': `Pipeline Fixture_Run {
   Work [Harness => Claude, Prompt => "Read notes.txt, write result.txt and list the folder."];
}
`,
  // A run that stays running until a test stops it: its one step answers only after two minutes.
  'Held_Run.synapse': `Pipeline Held_Run {
   Hold [Harness => Claude, Prompt => "Take your time."];
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
    {
      outcome: 'Changes_Requested',
      summary: 'one issue',
      data: { problems: [{ file: 'a.txt', location: '1', issue: 'one issue' }] },
      delay_seconds: 0.3,
    },
    { outcome: 'Approved', summary: 'looks good', data: {}, delay_seconds: 0.3 },
  ],
  Work: [{ outcome: 'Done', summary: 'worked', data: {}, delay_seconds: 0.1 }],
  Hold: [{ outcome: 'Done', summary: 'held', data: {}, delay_seconds: 120 }],
}

function write(path: string, text: string): void {
  mkdirSync(join(path, '..'), { recursive: true })
  writeFileSync(path, text)
}

// Runs git in a folder, as a person named A, and answers what it printed.
function git(folder: string, args: string[], env: NodeJS.ProcessEnv = process.env): string {
  const made = spawnSync('git', ['-c', 'user.name=A', '-c', 'user.email=a@example.com', ...args], {
    cwd: folder,
    encoding: 'utf8',
    env,
  })
  if (made.status !== 0) throw new Error(`git ${args[0]} failed: ${made.stderr}`)
  return made.stdout.trim()
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
    PATH: [world.bin, ...binDirs, join(world.pipelinePackage, 'bin'), process.env.PATH ?? ''].join(
      delimiter,
    ),
    XDG_CONFIG_HOME: world.xdg,
    SYNAPSE_PIPELINE_RUNNER: 'scripted',
    SYNAPSE_PIPELINE_SCRIPT: world.script,
    // Nothing the tests do may reach a vault, a work directory or a definition
    // directory that is not theirs.
    SYNAPSE_VAULT_DIR: '',
    SYNAPSE_WORK_DIR: world.work,
    SYNAPSE_PIPELINE_PATH: '',
    // A terminal of the app inherits this. The Integrations page types an `npm install -g`
    // into one, and a test of it must never install anything on the machine it runs on, nor
    // run the setup tools that come after it: npm only pretends, cannot reach the network and
    // has nothing in its cache, so it fails at once and the rest of the line does not run.
    npm_config_dry_run: 'true',
    npm_config_offline: 'true',
    npm_config_cache: join(world.root, 'npm-cache'),
    SYNAPSE_STUB_LOG: join(world.root, 'stub-args.log'),
    SYNAPSE_STUB_LIST_LOG: join(world.root, 'model-reads.log'),
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

// The shell functions both stubs use to answer a headless run. Started with `--output-format
// stream-json` the stub prints events the way Claude Code does: first an action, and at the end
// its result and the final `result` line. Otherwise it prints plain text as before. A prompt with
// SLOWCASE waits 30 seconds after the first event, so a test can see the action and then stop it.
const STREAM_SH = String.raw`
ev_start() {
  if [ "$STUB_STREAM" = 1 ]; then
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"Bash","input":{"command":"synapse vault-read research/Target.md"}}]}}'
  fi
}
ev_slow() {
  case "$1" in *SLOWCASE*) sleep 30 ;; esac
}
ev_end() {
  if [ "$STUB_STREAM" = 1 ]; then
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s1","content":"read"}]}}'
    printf '{"type":"result","subtype":"success","result":"%s"}\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}
`

// A harness that prints what it was started with, writes a session file in the
// form of the real one, and then echoes each line that is typed, until the line
// `quit`, which ends it with code 7. Asked for `claude -p /usage`, it prints `claudeUsage`, the
// JSON of a real run.
const stubScript = (claudeUsage: string): string =>
  [
    '#!/bin/sh',
    'name=$(basename "$0")',
    STREAM_SH,
    'STUB_STREAM=0',
    'case "$*" in *stream-json*) STUB_STREAM=1 ;; esac',
    'export STUB_STREAM',
    // Asked for its version, as `synapse doctor` does, it says one and touches nothing.
    '[ "$1" = "--version" ] && { echo "$name 0.0.0-stub"; exit 0; }',
    // Asked for its usage, as the status bar does, Claude Code prints the JSON of a real run.
    `[ "$name" = claude ] && [ "$1" = -p ] && [ "$2" = /usage ] && { cat <<'USAGE_JSON'\n${claudeUsage}\nUSAGE_JSON\nexit 0; }`,
    // Asked to serve its app-server, as the status bar does to read rate limits, Codex exits at
    // once, so its reading is unavailable without the 20-second wait.
    '[ "$name" = codex ] && [ "$1" = app-server ] && exit 1',
    // A listing of models is logged, for a test to see which programs the app ran to read them.
    '{ [ "$name" = claude ] && [ "$1" = -p ] && [ "$2" = /model ]; } || { [ "$name" = codex ] && [ "$1" = debug ]; } || { [ "$name" = opencode ] && { [ "$1" = models ] || [ "$1" = auth ]; }; } && [ -n "$SYNAPSE_STUB_LIST_LOG" ] && echo "$name $*" >> "$SYNAPSE_STUB_LIST_LOG"',
    // Asked for its models, as the app does to offer a choice of one: Claude Code answers its /model
    // command, Codex renders its catalogue and OpenCode lists its models and its providers.
    '[ "$name" = claude ] && [ "$1" = -p ] && [ "$2" = /model ] && { echo "Current model: Stub 1"; echo "Usage: /model <name>. Available: sonnet, opus, haiku, default, or a full model ID."; exit 0; }',
    `[ "$name" = codex ] && [ "$1" = debug ] && [ "$2" = models ] && { echo '{"models":[{"slug":"gpt-stub-b","display_name":"Stub B","description":"The second.","visibility":"list","priority":2},{"slug":"gpt-stub-a","display_name":"Stub A","description":"The first.","visibility":"list","priority":1},{"slug":"gpt-stub-old","display_name":"Old","visibility":"hide","priority":3}]}'; exit 0; }`,
    '[ "$name" = opencode ] && [ "$1" = models ] && { printf "%s\\n" opencode/glm-5.3-flash-free openrouter/z-ai/glm-5.3-flash openrouter/deepseek/deepseek-v4-flash anthropic/claude-sonnet-5; exit 0; }',
    '[ "$name" = opencode ] && [ "$1" = auth ] && { echo "OpenRouter  API key  stored"; exit 0; }',
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
    // The arguments of a background run are logged, for a test to see which model it was asked for.
    '[ -n "$headless" ] && [ -n "$SYNAPSE_STUB_LOG" ] && echo "$name $*" >> "$SYNAPSE_STUB_LOG"',
    'if [ -n "$headless" ]; then',
    '  if [ "$headless" = stdin ]; then prompt=$(cat); else for a in "$@"; do prompt=$a; done; fi',
    '  case "$prompt" in',
    '    *FAILCASE*) ev_end "FAILED: the stub was asked to fail"; exit 0 ;;',
    '    *LIVECASE*) exec "$(dirname "$0")/stub-live" ;;',
    '    *"Change one note that already exists"*) exec "$(dirname "$0")/stub-edit" "$prompt" ;;',
    '  esac',
    '  ev_start; ev_slow "$prompt"',
    `  printf '%s\\n' "# Stub note" "" "Written by $name" "$prompt" | synapse vault-write "research/Stub note.md"`,
    '  ev_end "research/Stub note.md"; exit 0',
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
    // Started with `edit`, it also edits a.txt in the folder it was started in, as a conversation
    // that changes a file does.
    '  case "$*" in *edit*)',
    `    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"%s/a.txt","old_string":"two","new_string":"TWO"}}]}}\\n' "$(pwd)" >> "$f"`,
    `    printf '%s\\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"edited"}]}}' >> "$f" ;;`,
    '  esac',
    'fi',
    // Resumed by its id, it carries on the session file of that id, in whichever project it is.
    'rid=""; prev=""',
    'for a in "$@"; do [ "$prev" = "--resume" ] && rid="$a"; prev="$a"; done',
    'if [ "$name" = claude ] && [ -n "$rid" ] && [ -z "$sid" ]; then',
    '  f=$(ls "$HOME"/.claude/projects/*/"$rid".jsonl 2>/dev/null | head -n 1)',
    `  [ -n "$f" ] && printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"Carry on"}}\\n' "$(pwd)" >> "$f"`,
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

// What `claude -p /usage --output-format json` printed in one real run.
const CLAUDE_USAGE = join(import.meta.dirname, '..', 'shared', 'examples', '_usage-claude.json')

// What the stub harness does when it is asked to change a note: it adds a line that holds
// the description to the note named in the prompt, or changes nothing, or also moves the
// date of another note, as the description says.
const EDIT_STUB =
  String.raw`#!/bin/sh
prompt="$1"
` +
  STREAM_SH +
  String.raw`
path=$(printf '%s\n' "$prompt" | sed -n 's/.*The note is .\(.*\).: read it first.*/\1/p')
desc=$(printf '%s\n' "$prompt" | sed -n '/^Description:$/,$p' | tail -n +2)
ev_start
ev_slow "$prompt"
case "$desc" in
  *NOCHANGE*) ev_end EDITED; exit 0 ;;
esac
tmp=$(mktemp)
synapse vault-read "$path" > "$tmp"
printf '\nStub edit: %s\n' "$desc" >> "$tmp"
synapse vault-write "$path" < "$tmp"
case "$desc" in
  *TOUCHOTHER*)
    synapse vault-read "research/Other.md" | sed 's/^updated: .*/updated: 2099-01-01T00:00:00+00:00/' > "$tmp"
    synapse vault-write "research/Other.md" < "$tmp" ;;
esac
rm -f "$tmp"
ev_end EDITED
`

// A headless session of Claude that says something, edits a.txt in its folder, and then takes
// its time before it answers, so a test can look at the step while it runs. It prints each event
// as it happens, as `claude --output-format stream-json` does.
const LIVE_STUB = String.raw`#!/bin/sh
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at a.txt."}]}}'
sleep 2
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"l1","name":"Edit","input":{"file_path":"%s/a.txt","old_string":"two","new_string":"TWO"}}]}}\n' "$(pwd)"
sed 's/two/TWO/' a.txt > a.txt.new && mv a.txt.new a.txt
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"l1","content":"edited"}]}}'
sleep 12
printf '%s\n' '{"type":"result","subtype":"success","result":"{\"outcome\":\"Done\",\"summary\":\"changed a.txt\",\"data\":{}}"}'
`

// `synapse-pipeline` as the tests see it: an interactive run needs the process runner, which runs
// the stub harness in a terminal, so it is run without the scripted one that every other run has.
// The same goes for the Live_Run pipeline, which runs the stub harness headless in its own folder.
const PIPELINE_WRAPPER = String.raw`#!/bin/sh
self=$(cd "$(dirname "$0")" && pwd)
whole=$PATH
rest=""
IFS=:
for d in $PATH; do
  [ "$d" = "$self" ] && continue
  if [ -n "$rest" ]; then rest="$rest:$d"; else rest="$d"; fi
done
unset IFS
PATH=$rest
real=$(command -v synapse-pipeline)
PATH=$whole
for a in "$@"; do
  if [ "$a" = "--interactive" ]; then
    unset SYNAPSE_PIPELINE_RUNNER SYNAPSE_PIPELINE_SCRIPT
  fi
  if [ "$a" = "Live_Run" ]; then
    unset SYNAPSE_PIPELINE_RUNNER SYNAPSE_PIPELINE_SCRIPT
    cd "$self/../live-project" || exit 1
  fi
done
exec "$real" "$@"
`

export function buildWorld(root: string, binDirs: readonly string[]): World {
  const world = worldAt(root)
  mkdirSync(world.home, { recursive: true })
  mkdirSync(world.data, { recursive: true })
  mkdirSync(world.bin, { recursive: true })
  const stub = stubScript(readFileSync(CLAUDE_USAGE, 'utf8').trim())
  for (const name of ['claude', 'codex', 'opencode']) {
    writeFileSync(join(world.bin, name), stub, { mode: 0o755, flag: 'w' })
  }
  writeFileSync(join(world.bin, 'synapse-pipeline'), PIPELINE_WRAPPER, { mode: 0o755, flag: 'w' })
  writeFileSync(join(world.bin, 'stub-edit'), EDIT_STUB, { mode: 0o755, flag: 'w' })
  writeFileSync(join(world.bin, 'stub-live'), LIVE_STUB, { mode: 0o755, flag: 'w' })
  for (const [name, text] of Object.entries(DEFINITIONS)) write(join(world.definitions, name), text)
  for (const [name, text] of Object.entries(SKILLS)) {
    write(join(world.definitions, 'skills', name, 'SKILL.md'), text)
  }
  write(join(world.pipelinePackage, 'bin', 'synapse-pipeline'), '')
  write(
    join(world.pipelinePackage, 'skills', 'synapse-pipeline', 'SKILL.md'),
    readFileSync(
      join(
        import.meta.dirname,
        '..',
        '..',
        'packages',
        'synapse-pipeline',
        'skills',
        'synapse-pipeline',
        'SKILL.md',
      ),
      'utf8',
    ),
  )
  write(world.script, JSON.stringify(ANSWERS, null, 2))
  resetSettings(world)
  mkdirSync(world.work, { recursive: true })

  // The folder of the Live_Run pipeline, a repository with one commit.
  write(join(world.live, 'a.txt'), 'one\ntwo\nthree\n')
  for (const args of [
    ['init', '-q'],
    ['add', '-A'],
    ['commit', '-q', '-m', 'first'],
  ]) {
    git(world.live, args)
  }

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

  // A finished run, made by the program itself in a repository of its own, with the transcript
  // that a scripted run does not write put in its record.
  write(join(world.project, 'notes.txt'), 'pineapple\n')
  write(join(world.project, 'src', 'render.adb'), RENDER_BEFORE)
  for (const args of [
    ['init', '-q'],
    ['add', '-A'],
    ['commit', '-q', '-m', 'first'],
  ]) {
    git(world.project, args)
  }
  const id = 'exec-fixture1'
  const run = spawnSync('synapse-pipeline', ['run', 'Fixture_Run', '--id', id], {
    cwd: world.project,
    env: environmentFor(world, binDirs),
    encoding: 'utf8',
  })
  if (run.status !== 0) {
    throw new Error(`the fixture run failed: ${run.stderr}${run.error ? String(run.error) : ''}`)
  }
  const record = join(world.work, 'pipelines', id)
  const transcript = join(record, 'transcripts', '1-Work-1.jsonl')
  write(transcript, claudeTranscript(world.project))
  // What the step changed in its folder, as a run keeps it: a file that existed and a new file with
  // its content, and a new file whose content was past the limit, which the patch alone has.
  write(join(record, 'patches', '1-Work-1.patch'), WORK_PATCH)
  const events = join(record, 'events.jsonl')
  writeFileSync(
    events,
    readFileSync(events, 'utf8').replace(
      '"transcript":null',
      `"transcript":${JSON.stringify(transcript)}`,
    ),
  )
  // A scripted step writes nothing, so the run's end is pinned again with what the step would have
  // written: the files in the folder now, as a snapshot from an index of its own.
  write(join(world.project, 'src', 'render.adb'), RENDER_AFTER)
  write(join(world.project, 'result.txt'), 'pineapple\n')
  write(
    join(world.project, 'src', 'fresh.adb'),
    'procedure Fresh is null;\n-- written by the step\n',
  )
  const index = { ...process.env, GIT_INDEX_FILE: join(world.root, 'project-index') }
  git(world.project, ['read-tree', 'HEAD'], index)
  git(world.project, ['add', '-A'], index)
  const end = git(world.project, ['write-tree'], index)
  git(world.project, ['update-ref', `refs/synapse/runs/${id}/end`, end])
  const summary = join(record, 'execution.json')
  const kept = JSON.parse(readFileSync(summary, 'utf8')) as { snapshots: { end: string | null } }
  kept.snapshots.end = end
  writeFileSync(summary, JSON.stringify(kept))
  return world
}

const RENDER_BEFORE = `procedure Render is
   Done : Boolean := False;
begin
   null;
end Render;
`

const RENDER_AFTER = RENDER_BEFORE.replace('False', 'True')

const WORK_PATCH = `diff --git a/src/render.adb b/src/render.adb
index 1111111..2222222 100644
--- a/src/render.adb
+++ b/src/render.adb
@@ -1,3 +1,3 @@
 procedure Render is
-   Done : Boolean := False;
+   Done : Boolean := True;
 begin
diff --git a/data/huge.dat b/data/huge.dat
new file mode 100644
--- /dev/null
+++ b/data/huge.dat
@@ -0,0 +1,40000 @@
\\ Content not kept
diff --git a/result.txt b/result.txt
new file mode 100644
--- /dev/null
+++ b/result.txt
@@ -0,0 +1 @@
+pineapple
diff --git a/src/fresh.adb b/src/fresh.adb
new file mode 100644
--- /dev/null
+++ b/src/fresh.adb
@@ -0,0 +1,2 @@
+procedure Fresh is null;
+-- written by the step
`
