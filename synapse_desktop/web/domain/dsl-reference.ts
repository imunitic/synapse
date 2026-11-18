// What a person needs to write a definition by hand: its shape, the attributes it may carry and
// the rules it is held to. It is the language reference of the documentation, cut to the kind
// being written, and a test holds it to the attribute table of the language's own source.

export type DslKind = 'pipeline' | 'system' | 'agent'

// Where an attribute may be written.
export type DslWhere = 'step' | 'edge' | 'system' | 'agent'

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
    on: ['step', 'system', 'agent'],
    value: 'string',
    meaning: 'Instructions, inline. A block of triple quotes holds several paragraphs.',
  },
  {
    name: 'Skill',
    on: ['step', 'system', 'agent'],
    value: 'name',
    meaning: 'Instructions from a skill. A step gives a Prompt or a Skill, not both.',
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
    meaning: 'The outcomes the step may end with, each with what it means. Optional.',
  },
  { name: 'When', on: ['edge'], value: 'outcome name or JSON', meaning: 'The guard of the edge.' },
  {
    name: 'Max_Iterations',
    on: ['edge'],
    value: 'integer, at least 1',
    meaning: 'How many times the edge may fire.',
  },
]

// The attributes a kind of definition is written with: a pipeline has steps and edges, a system
// is a step's setup, and an agent a role.
const WHERE: Record<DslKind, readonly DslWhere[]> = {
  pipeline: ['step', 'edge'],
  system: ['system'],
  agent: ['agent'],
}

export function attributesFor(kind: DslKind): DslAttribute[] {
  return DSL_ATTRIBUTES.filter((a) => a.on.some((where) => WHERE[kind].includes(where)))
}

// A definition of each kind that is valid as it is, with names to be changed.
export const DSL_SHAPES: Record<DslKind, string> = {
  pipeline: `-- What the pipeline does.
Pipeline Name {
   Step_One [Harness => Claude, Prompt => "Do the first thing."];
   Step_Two [Harness => Claude, Prompt => "Check it."];
   Step_One -> Step_Two;
   Step_Two -> Step_One [When => Changes_Requested, Max_Iterations => 3];
}`,
  system: `System Name [Harness => Claude, Permissions => Read_Only, Prompt => "Say what it does."];`,
  agent: `Agent Name [Prompt => "You are a reviewer. Say who the session is."];`,
}

const COMMON = [
  'The file is `Name.synapse` and declares the same name: letters, digits and underscores, starting with a letter. Case matters.',
  'A comment runs from `--` to the end of the line. A string is in double quotes, with JSON escapes.',
  'An unknown attribute, one that is not allowed where it is written and one written twice are errors.',
]

export const DSL_RULES: Record<DslKind, readonly string[]> = {
  pipeline: [
    ...COMMON,
    'A step is `Name [attributes];`. Steps run in the order they are written unless an edge sends control elsewhere.',
    'An edge is `From -> To [attributes];`, and `A -> B -> C` is one edge for each pair. An edge to a step that is not written is an error.',
    'An edge back to an earlier step, or to itself, needs `Max_Iterations`.',
    'A step gives its whole setup, or names a `System` and overrides what it likes. Its own Prompt or Skill replaces the system’s.',
    'The harness comes from the step, else its system, else the `SYNAPSE_PIPELINE_HARNESS` variable. A step with none is an error.',
  ],
  system: [
    ...COMMON,
    'A system is the setup of a step, named so that steps can share it. A system cannot name another system.',
    'It gives a Prompt or a Skill, not both.',
  ],
  agent: [
    ...COMMON,
    'An agent says who the session is, with a Prompt or a Skill, and has no harness. The step says what to do.',
  ],
}
