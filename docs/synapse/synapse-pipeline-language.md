# Synapse Pipeline definition language

The format of the files `synapse-pipeline` reads: how to write a pipeline, the systems and agents it
refers to, and the rules that decide what runs when. For running a pipeline, the commands and the
environment, see [synapse-pipeline.md](synapse-pipeline.md).

A definition is a small declarative text, limited to declarations and references. There is no
expression language, no variable and no inline definition: a pipeline says which steps there are,
what each one is, and how control moves between them.

## An example

`Develop_Feature.synapse`:

```
-- Build a change, then have it reviewed until it is approved.
Pipeline Develop_Feature {
   Develop [Agent => Developer, Harness => Claude, Prompt => "Implement the supplied task."];
   Test    [Agent => Tester, Harness => Claude, Skill => "test-feature"];
   Review  [System => Strict_Reviewer, Harness => Codex];
   Review -> Develop [When => Changes_Requested, Max_Iterations => 5];
}
```

`Strict_Reviewer.synapse`:

```
System Strict_Reviewer [Agent => Reviewer, Harness => Claude, Permissions => Read_Only, Skill => "review-code"];
```

`Reviewer.synapse`:

```
Agent Reviewer [Prompt => "You are a reviewer. Find what is wrong with the change; do not fix it."];
```

## Files and names

- A definition file has the extension `.synapse` and holds exactly one definition. Its first word says
  which kind: `Pipeline`, `System` or `Agent`.
- The file's name, without the extension, is the name the definition declares: `Reviewer.synapse`
  declares `Agent Reviewer`. A file whose name differs from its declaration is an error.
- Definitions are found in the directories listed in `SYNAPSE_PIPELINE_PATH` (separated as the
  directories of a `PATH` are) and in `$XDG_CONFIG_HOME/synapse-pipeline/`, or
  `~/.config/synapse-pipeline/` when that variable is unset. A directory that does not exist is
  skipped, and one named in `SYNAPSE_PIPELINE_PATH` is reported as a warning.
- There is no import. Every file in those directories is loaded before any pipeline is checked, into
  one namespace: a name belongs to exactly one definition whatever its kind. A name claimed by two
  files belongs to neither.
- A file that does not load does not stop the others. What is wrong with it is reported as a warning,
  and a pipeline that needs it fails at once, before any session starts, saying why.

## Lexical rules

| | |
|---|---|
| Source | UTF-8. Whitespace is insignificant outside strings. |
| Comment | From `--` to the end of the line. |
| Identifier | A letter followed by letters, digits and underscores. Case-sensitive. |
| String | Double-quoted, with JSON escapes. A triple-quoted block `"""..."""` takes everything up to the closing triple quote as it is, for a prompt of several paragraphs. |
| Integer | Plain decimal. |
| Duration | A quoted string with a number and a unit of `s`, `m` or `h`: `"90s"`, `"30m"`, `"2h"`. |
| JSON value | After `=>`, a `{` or `[` begins a JSON value that runs to its matching close. |
| Reserved | `Pipeline`, `System`, `Agent` and `End`. Attribute names have a namespace of their own, so a step may be called `Test`. |

## The three kinds

| Kind | What it is |
|---|---|
| `Pipeline` | A set of steps and the edges between them. |
| `System` | A named, reusable partial step: the setup a session runs with. |
| `Agent` | A role: a `Prompt` or a `Skill` that says who the session is, such as "You are a tester." It is independent of any harness. |

A step is a system and a system is a step: a step either gives its whole setup itself or names a
system with `System =>` and overrides what it likes. An agent says who the session is, and the step's
own prompt or skill says what to do.

Everything is referred to by name. `Agent =>` and `System =>` take the name of a definition; there are
no inline or anonymous definitions. A reference is checked for the kind its attribute expects, so
`System => Reviewer` is an error if `Reviewer` is an agent.

## Pipelines

A pipeline body holds steps and edges.

```
Pipeline Name {
   Step_Name [attribute list];
   From_Step -> To_Step [attribute list];
   A -> B -> C [attribute list];
}
```

- A step is `Step_Name [attributes];`. The steps run in the order they are declared unless an edge
  redirects control.
- An edge is `From -> To [attributes];`. A chain `A -> B -> C` is one edge for each pair, each with the
  attributes given. An edge to a step that is not declared is an error.
- An attribute list is comma-separated `Name => value` pairs. The list can be left out.

## Attributes

| Attribute | On | Value | Meaning |
|---|---|---|---|
| `Agent` | step, system | name | The agent that sets the role. |
| `System` | step | name | The system the step is built from. |
| `Prompt` | step, system, agent | string | Instructions, inline. |
| `Skill` | step, system, agent | name | Instructions from a skill. |
| `Harness` | step, system | `Claude`, `Codex` or `Opencode` | What runs the session. |
| `Model` | step, system | name or string | The model the harness is asked to use. |
| `Permissions` | step, system | `Read_Only`, `Workspace_Write` or `Full_Access` | What the session may do. Default `Workspace_Write`. |
| `Tools` | step, system | JSON list of strings | The tools the session may use. Only Claude can honour it. |
| `Timeout` | step, system | duration | The most one session may take. |
| `Retries` | step, system | integer | Extra tries after an execution error or a result that breaks the contract. |
| `When` | edge | outcome name or JSON | The guard. |
| `Max_Iterations` | edge | integer, at least 1 | How many times the edge may fire. |

- An unknown attribute, an attribute that is not allowed where it is written, and an attribute written
  twice on one node are errors.
- `Prompt` and `Skill` are alternatives: a node gives one or the other.
- Every back-edge, an edge to a step that is declared earlier than its own or to itself, must have
  `Max_Iterations`.
- A skill name has 1 to 64 lowercase letters, digits and single hyphens.
- Step names are written in `Pascal_Case` by convention.

### How a step is built

The values a session runs with come from the step, its system and its agent:

- A step's own attributes override the system's.
- `Prompt` or `Skill` written on the step replaces the system's `Prompt` or `Skill` as a unit.
- The agent's `Prompt` or `Skill` is the role. It is kept separate from the step's own instruction,
  which is the assignment.
- A system cannot name another system.
- The harness comes from the step, else its system, else `SYNAPSE_PIPELINE_HARNESS`. A step that ends
  up with none is an error.
- A session's time limit is the step's `Timeout`, else `SYNAPSE_PIPELINE_TIMEOUT`, else 30 minutes.

## Skills

A skill is a directory `<name>/` holding a `SKILL.md`, in the form of the
[Agent Skills](https://agentskills.io) specification. It is looked for in
`$XDG_CONFIG_HOME/synapse-pipeline/skills/` (`~/.config/synapse-pipeline/skills/` when that variable
is unset). A skill that is not there is an error that names the directories searched. Looking a skill
up needs no harness. When the step runs, the skill's `SKILL.md` becomes part of the prompt together
with the directory its other files are in.

## Results and guards

Every step ends with one result, in a fixed shape:

```json
{"outcome": "Changes_Requested", "summary": "Two tests fail.", "data": {"failing": 2}}
```

- `outcome` is a non-empty string: one word naming what happened. Guards route on it.
- `summary` is a string, for a person.
- `data` is an object, empty if there is nothing to hand on. The step's prompt or skill says which
  fields it should hold.
- Any other member makes the result invalid, so a guard has exactly these three things to read.

The next step is given the pipeline's initial input and the previous step's result. The last step's
result is the result of the run.

A guard is the `When` of an edge:

- A bare name is a test of the outcome: `When => Changes_Requested` means the same as
  `When => {"==": [{"var": "outcome"}, "Changes_Requested"]}`.
- A JSON value is a [JsonLogic](https://jsonlogic.com) rule over the result that has just been
  produced: `When => {">": [{"var": "data.failing"}, 0]}`. It sees `outcome`, `summary` and `data`
  and nothing else; a missing field reads as `null`. A `var` path follows object members only, not
  positions in a list.
- It has to give true or false. A rule that gives anything else fails the step as an execution error.
  A rule that names an operator the evaluator does not have is an error in the definition.
- An edge with no `When` is taken whenever it is reached.

After a step finishes, the edges that leave it are tried in the order they were written and the first
whose guard holds is taken. An edge that has already fired `Max_Iterations` times is passed over
without its guard being evaluated. When no edge is taken, control moves to the next declared step, and
from the last step the run is complete.

### Ending a run early

`End` is not a step but a place an edge can lead to: `Check -> End [When => Discussing]`. Taking that
edge completes the run at once, with no session, and the run's result is the result of the step the
edge leaves, as it is when the last step finishes. The run is a successful completion like any other,
so the exit code is 0 and a caller reads the outcome in the result. The edge is otherwise an ordinary
one: it has a guard, it is tried in the order written with the other edges leaving the step, it is
counted, and it can have `Max_Iterations`. `End` cannot be the name of a step or of a definition, and
nothing can leave it, so `A -> End -> B` is an error.

```
Pipeline Build_Ready_Note {
   Check [Harness => Claude, Prompt => "Report Ready if the design note is Ready, otherwise Discussing."];
   Build [Harness => Claude, Prompt => "Implement the note."];
   Check -> End [When => Discussing];
}
```

## Failures

A step that cannot produce a result fails the run at that step. A failed run does not move on, and
nothing in the pipeline can catch the failure.

| Failure | Meaning |
|---|---|
| `execution_error` | The session could not be run, ran past its time limit, or failed. Retried as many times as `Retries` says. |
| `result_contract_failure` | The session ended but its answer is not a valid result. Retried as many times as `Retries` says. |
| `quota_exhausted` | The harness said a limit was reached. Never retried; the harness's reset time is reported when it gives one. |
| `ceiling_reached` | The run took `SYNAPSE_PIPELINE_MAX_STEPS` steps (default 50) without completing. |

## What is checked before anything runs

`synapse-pipeline check` and `synapse-pipeline run` check, before the first session starts:

- the grammar, with the file, line and column of every error;
- that every step, edge, system, agent and skill that is named exists, and is of the right kind (an edge may also lead to `End`);
- that every step has a harness, a known permission level and a well-formed duration;
- that `Prompt` and `Skill` are not both given, and that a system does not name a system;
- that every guard is a rule the evaluator can run, and every back-edge is bounded.

All the problems found are reported together.
