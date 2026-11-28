// What a person needs to write a definition by hand: its shape, the attributes it may carry and
// the rules it is held to. It is the language reference of the documentation, cut to the kind
// being written, and a test holds it to the attribute table of the language's own source.

export type DslKind = 'pipeline' | 'system' | 'agent' | 'prompt'

// Where an attribute may be written: `pipeline` is the attribute list of a pipeline itself.
export type DslWhere = 'pipeline' | 'step' | 'edge' | 'system' | 'agent' | 'prompt'

export interface DslAttribute {
  name: string
  on: readonly DslWhere[]
  value: string
  meaning: string
}

export const DSL_ATTRIBUTES: readonly DslAttribute[] = [
  {
    name: 'Agent',
    on: ['step', 'system'],
    value: 'name',
    meaning: 'The agent that sets the role.',
  },
  { name: 'System', on: ['step'], value: 'name', meaning: 'The system the step is built from.' },
  {
    name: 'Prompt',
    on: ['step', 'system', 'agent', 'prompt'],
    value: 'string, or the name of a Prompt definition; on a prompt, a string',
    meaning:
      'Instructions: the text itself, or the text of that definition. A block of triple quotes holds several paragraphs.',
  },
  {
    name: 'Description',
    on: ['pipeline', 'system', 'agent', 'prompt'],
    value: 'string',
    meaning: 'A short text for a person. Not part of any prompt.',
  },
  {
    name: 'Harness',
    on: ['step', 'system'],
    value: 'Claude, Codex or Opencode',
    meaning: 'What runs the session.',
  },
  {
    name: 'Model',
    on: ['step', 'system'],
    value: 'name or string',
    meaning: 'The model the harness is asked to use. Without one, the harness uses its own.',
  },
  {
    name: 'Effort',
    on: ['step', 'system'],
    value: 'name or string',
    meaning:
      'How much effort the model is asked to put in. Claude: low, medium, high, xhigh, max. Codex: none, minimal, low, medium, high, xhigh, max, ultra, persistent. OpenCode: a variant of the model, which needs a Model.',
  },
  {
    name: 'Permissions',
    on: ['step', 'system'],
    value: 'Read_Only, Workspace_Write or Full_Access',
    meaning: 'What the session may do. Without it, Workspace_Write.',
  },
  {
    name: 'Timeout',
    on: ['step', 'system'],
    value: 'a quoted duration: "90s", "30m", "2h"',
    meaning: 'The most one session may take.',
  },
  {
    name: 'Retries',
    on: ['step', 'system'],
    value: 'integer',
    meaning: 'Extra tries after an execution error or a result that breaks the contract.',
  },
  {
    name: 'Outcomes',
    on: ['step', 'system'],
    value: 'JSON object',
    meaning:
      'The outcomes the step may end with, each with what it means. A meaning may be `{"description": "...", "data": {...}}`, with the fields the result holds with that outcome; that `data` may also be a list of names the pipeline declares. Optional.',
  },
  {
    name: 'Data',
    on: ['pipeline', 'step', 'system'],
    value: 'JSON object; on a step or system also a list of names',
    meaning:
      "On a pipeline, the shapes of the fields its steps hand on, declared once. On a step, the fields its result holds in `data`, each with what it means, or the names of fields the pipeline declares; an outcome's `data` may name them too. The next step gets them as its input. Optional.",
  },
  {
    name: 'Input',
    on: ['pipeline'],
    value: 'JSON object',
    meaning: "The fields the pipeline's input has, each with what it means. Optional.",
  },
  { name: 'When', on: ['edge'], value: 'outcome name or JSON', meaning: 'The guard of the edge.' },
  {
    name: 'Max_Iterations',
    on: ['edge'],
    value: 'integer, at least 1',
    meaning: 'How many times the edge may fire.',
  },
]

// The attributes a kind of definition is written with: a pipeline has its own attribute list,
// steps and edges, a system is a step's setup, an agent a role, and a prompt a text.
const WHERE: Record<DslKind, readonly DslWhere[]> = {
  pipeline: ['pipeline', 'step', 'edge'],
  system: ['system'],
  agent: ['agent'],
  prompt: ['prompt'],
}

export function attributesFor(kind: DslKind): DslAttribute[] {
  return DSL_ATTRIBUTES.filter((a) => a.on.some((where) => WHERE[kind].includes(where)))
}

// A definition of each kind that is valid as it is, with names to be changed.
export const DSL_SHAPES: Record<DslKind, string> = {
  pipeline: `-- What the pipeline does.
Pipeline Name [Description => "What the pipeline does."] {
   Step_One [Harness => Claude, Prompt => "Do the first thing."];
   Step_Two [Harness => Claude, Prompt => "Check it."];
   Step_One -> Step_Two;
   Step_Two -> Step_One [When => Changes_Requested, Max_Iterations => 3];
}`,
  system: `System Name [Harness => Claude, Permissions => Read_Only, Prompt => "Say what it does."];`,
  agent: `Agent Name [Prompt => "You are a reviewer. Say who the session is."];`,
  prompt: `Prompt Name [Description => "What the prompt is for.", Prompt => """
Say what to do.
"""];`,
}

const COMMON = [
  'The file is `Name.synapse` and declares the same name: letters, digits and underscores, starting with a letter. Case matters.',
  'A comment runs from `--` to the end of the line. A string is in double quotes, with JSON escapes.',
  'An unknown attribute, one that is not allowed where it is written and one written twice are errors.',
]

export const DSL_RULES: Record<DslKind, readonly string[]> = {
  pipeline: [
    ...COMMON,
    'A pipeline may carry an attribute list between its name and `{`: `Pipeline Name [Description => "..."] {`.',
    'A step is `Name [attributes];`. Steps run in the order they are written unless an edge sends control elsewhere.',
    'An edge is `From -> To [attributes];`, and `A -> B -> C` is one edge for each pair. An edge to a step that is not written is an error.',
    'An edge back to an earlier step, or to itself, needs `Max_Iterations`.',
    'A step gives its whole setup, or names a `System` and overrides what it likes. Its own Prompt replaces the system’s, whether each is a text or a name.',
    'The harness comes from the step, else its system, else the `SYNAPSE_PIPELINE_HARNESS` variable. A step with none is an error.',
    'A field several steps hand on is declared once in the pipeline’s `Data` and named in each step: `Data => ["task_note"]`. A name means one thing in the whole pipeline.',
  ],
  system: [
    ...COMMON,
    'A system is the setup of a step, named so that steps can share it. A system cannot name another system.',
    'Its Prompt is the text itself or the name of a Prompt definition.',
    'A system’s `Data` may name fields the pipeline declares; each pipeline that uses the system must declare them.',
  ],
  agent: [
    ...COMMON,
    'An agent says who the session is, with a Prompt, and has no harness. The step says what to do.',
    'Its Prompt is the text itself or the name of a Prompt definition.',
  ],
  prompt: [
    ...COMMON,
    'A prompt is text only: a step, a system or an agent uses it with `Prompt => Name`, and its text becomes part of the step’s prompt.',
    'Its Prompt is a string and must not be empty.',
    'Files next to a prompt have no place in it. A step that needs files names their location in its prompt and gets access through its Permissions.',
  ],
}
