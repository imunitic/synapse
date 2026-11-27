# Synapse Pipeline definition language

The format of the files `synapse-pipeline` reads: how to write a pipeline, the systems, agents and
prompts it refers to, and the rules that decide what runs when. For running a pipeline, the commands and the
environment, see [synapse-pipeline.md](synapse-pipeline.md).

A definition is a small declarative text, limited to declarations and references. There is no
expression language, no variable and no inline definition: a pipeline says which steps there are,
what each one is, and how control moves between them.

## An example

`Develop_Feature.synapse`:

```
-- Build a change, then have it reviewed until it is approved.
Pipeline Develop_Feature [Description => "Build a change and have it reviewed."] {
   Develop [Agent => Developer, Harness => Claude, Prompt => "Implement the supplied task."];
   Test    [Agent => Tester, Harness => Claude, Prompt => Test_Feature];
   Review  [System => Strict_Reviewer, Harness => Codex];
   Review -> Develop [When => Changes_Requested, Max_Iterations => 5];
}
```

`Strict_Reviewer.synapse`:

```
System Strict_Reviewer [Agent => Reviewer, Harness => Claude, Permissions => Read_Only, Prompt => Review_Code];
```

`Review_Code.synapse`:

```
Prompt Review_Code [Description => "Review a change against its task.", Prompt => """
Read the change and the task it was made for. Report every problem you find in data.problems.
"""];
```

`Reviewer.synapse`:

```
Agent Reviewer [Prompt => "You are a reviewer. Find what is wrong with the change; do not fix it."];
```

## Files and names

- A definition file has the extension `.synapse` and holds exactly one definition. Its first word says
  which kind: `Pipeline`, `System`, `Agent` or `Prompt`.
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
| Reserved | `Pipeline`, `System`, `Agent`, `Prompt` and `End`. Attribute names have a namespace of their own, so a step may be called `Test`. |

## The four kinds

| Kind | What it is |
|---|---|
| `Pipeline` | A set of steps and the edges between them. |
| `System` | A named, reusable partial step: the setup a session runs with. |
| `Agent` | A role: a `Prompt` that says who the session is, such as "You are a tester." It is independent of any harness. |
| `Prompt` | A named, reusable text of instructions. A step, a system or an agent uses it with `Prompt => Name`. |

Every kind can have a `Description`: a short text for a person, such as a list of definitions shows.
It is never part of a session's prompt.

A step is a system and a system is a step: a step either gives its whole setup itself or names a
system with `System =>` and overrides what it likes. An agent says who the session is, and the step's
own prompt says what to do.

Everything is referred to by name. `Agent =>` and `System =>` take the name of a definition, and
`Prompt =>` takes either a string or the name of a `Prompt` definition; there are
no inline or anonymous definitions. A reference is checked for the kind its attribute expects, so
`System => Reviewer` is an error if `Reviewer` is an agent.

## Pipelines

A pipeline body holds steps and edges. An attribute list between the name and the body is optional,
and takes only `Description` and `Input`.

```
Pipeline Name [Description => "..."] {
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
| `Prompt` | step, system, agent | string, or the name of a Prompt definition | Instructions: the text itself, or the text of that definition. |
| `Prompt` | prompt | string | The prompt's text. |
| `Description` | pipeline, system, agent, prompt | string | A short text for a person. Not part of any prompt. |
| `Input` | pipeline | JSON object | The fields the pipeline's input has, each with what it means. Optional; see [Input](#input). |
| `Harness` | step, system | `Claude`, `Codex` or `Opencode` | What runs the session. |
| `Model` | step, system | name or string | The model the harness is asked to use. |
| `Permissions` | step, system | `Read_Only`, `Workspace_Write` or `Full_Access` | What the session may do. Default `Workspace_Write`. |
| `Timeout` | step, system | duration | The most one session may take. |
| `Retries` | step, system | integer | Extra tries after an execution error or a result that breaks the contract. |
| `Outcomes` | step, system | JSON object | The outcomes the step may end with, each with what it means and, optionally, the data it hands on. Optional; see [Declaring outcomes](#declaring-outcomes). |
| `Data` | step, system | JSON object | The fields the step puts in `data` whatever its outcome, each with what it means. Optional; see [Declaring data](#declaring-data). |
| `When` | edge | outcome name or JSON | The guard. |
| `Max_Iterations` | edge | integer, at least 1 | How many times the edge may fire. |

- An unknown attribute, an attribute that is not allowed where it is written, and an attribute written
  twice on one node are errors.
- A string `Prompt` must not be empty.
- Every back-edge, an edge to a step that is declared earlier than its own or to itself, must have
  `Max_Iterations`.
- Step names are written in `Pascal_Case` by convention.

### How a step is built

The values a session runs with come from the step, its system and its agent:

- A step's own attributes override the system's.
- `Prompt` written on the step replaces the system's `Prompt`, whether each is a text or a name.
- The agent's `Prompt` is the role. It is kept separate from the step's own instruction,
  which is the assignment.
- A system cannot name another system.
- The harness comes from the step, else its system, else `SYNAPSE_PIPELINE_HARNESS`. A step that ends
  up with none is an error.
- A session's time limit is the step's `Timeout`, else `SYNAPSE_PIPELINE_TIMEOUT`, else 30 minutes.

## Prompts

A `Prompt` definition is text only: `Prompt Name [Description => "...", Prompt => """..."""];`. When a
step runs, the text of each prompt it names becomes part of its prompt, as an inline string would.

Files next to a prompt have no place in it. A step that needs files names their location in its
prompt, and gets access to them through its `Permissions`.

## Input

A pipeline may say what input it takes with `Input`. Its value is a JSON object in Synapse's schema
language: rules for each field, and JsonLogic `checks` for rules across fields. Vault note schemas
use the same language, so [Vault note schemas](synapse-note-schema.md) describes each rule in full:

```
Pipeline Implement_Task_Note [Input => {
  "fields": {
    "task_id": {"type": "string", "required": true,
                "pattern": "^[a-z][a-z0-9-]*-[0-9]{3,}$",
                "description": "The id of the Synapse Vault task note to implement, such as synapse-067."},
    "instructions": {"type": "string",
                     "description": "Extra requirements for this run only, in plain words."}
  }
}] {
   Implement [Harness => Claude, Prompt => "Implement the task note named by task_id."];
}
```

- `fields` is required and names at least one field. A field name is lowercase letters, digits and
  underscores, starting with a letter.
- Each field takes the schema language's field rules: `type` (`string`, `integer`, `boolean`,
  `timestamp` or `list`), `required`, `min_length`, `const`, `pattern` and `enum`. The rules that
  only make sense for a stored note, `mutable`, `format`, `timezone` and `update_on`, and the type
  `any`, are refused in an input.
- `description` is required on every field. It says what the field means, and the prompt shows it.
- A `list` says what its items are with `items`: a type name (`"items": "string"`), or
  `"items": {"fields": {...}}`, a set of fields written with exactly the same rules, lists included.
  There is no other way to give an input structure.
- `checks` is optional. It is a list of JsonLogic rules, each with an optional `message`. A rule reads
  the input's fields directly, as `{"var": "task_id"}`, and may use only the built-in operators. The
  checks run only when every field is right.

The input is closed: a field the declaration does not name is an error. An optional field given as
`""` or `[]` counts as not given, and is left out of the input the steps see. When the declaration has
exactly one required field and it is a `string`, a plain JSON string is accepted as that field, so
`echo '"synapse-067"' | synapse-pipeline run Implement_Task_Note --input -` works.

An input that breaks the declaration is refused before anything runs. `run`, `next --input`,
`check --input` and `show --step --input` report every problem, one `error:` line each, and exit
with code 2. A pipeline without `Input` accepts any input, or none, as it is.

With `Input`, each step's prompt shows the input as a list instead of raw JSON: every declared field in
order, its value, and its description on the next line. A field that was not given reads
`(not given)`. A string is written as it is, an integer or a boolean as JSON, and a list puts each item
on its own line, an item with fields as compact JSON. For the example above, started with
`{"task_id": "synapse-067"}`:

```
The pipeline was started with this input:
- task_id: synapse-067
  The id of the Synapse Vault task note to implement, such as synapse-067.
- instructions: (not given)
  Extra requirements for this run only, in plain words.
```

So a prompt refers to a field by its name ("the task note named by task_id") and need not explain it.
`show` reports the declaration, and `show --format json` gives it as `input`.

## Results and guards

Every step ends with one result, in a fixed shape:

```json
{"outcome": "Changes_Requested", "summary": "Two tests fail.", "data": {"failing": 2}}
```

- `outcome` is a non-empty string: one word naming what happened. Guards route on it.
- `summary` is a string, for a person.
- `data` is an object, empty if there is nothing to hand on. The step's `Data` and its outcomes'
  `data` say which fields it holds; see [Declaring data](#declaring-data).
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

### Declaring outcomes

A step may say which outcomes it can end with:

```
Review [System => Reviewer, Outcomes => {
  "Approved": "Every requirement is met and the tests pass. Choose this only if you found nothing to fix.",
  "Changes_Requested": "At least one requirement is unmet or a test fails."
}];
Review -> Develop [When => Changes_Requested, Max_Iterations => 5];
```

`Outcomes` is optional. A step without it ends with any word, and a guard can test any word. Declaring
them is strongly suggested wherever an edge tests the outcome, because then:

- the prompt lists the words and what each means, so a prompt need not name them and one prompt
  can serve pipelines that use different words;
- an edge whose guard tests a word the step does not declare is an error in the definition, so a
  misspelt outcome cannot make an edge that never fires;
- an answer with any other word is a `result_contract_failure`, tried again as `Retries` says.

A word is written like a name: a letter, then letters, digits and underscores, and not a keyword. Each
meaning is one line of text, and it is all the guidance the session gets on when to choose the word, so
it should state the condition for choosing it. What `data` holds with the word is declared, not
described; see the object form below and [Declaring data](#declaring-data). A step takes its own `Outcomes`, else its system's; an agent has none, so a
role can be used in pipelines that choose different words. Only a guard that tests nothing but the
outcome counts: a bare name or `{"==": [{"var": "outcome"}, "Word"]}`. A rule over `data` is not checked
against the words.

`check` warns, and still succeeds, when a step has edges that test its outcome and declares no
`Outcomes`. `show` reports them as `outcomes` on each step.

A meaning may also be written as an object, when the outcome hands on data of its own:

```
Implement [Agent => Developer, Harness => Claude, Prompt => Implement_Task_Item, Outcomes => {
  "Done": "The item is implemented and its tests pass.",
  "Blocked": {"description": "You could not finish the item.",
              "data": {"blocker": {"type": "string", "required": true,
                                   "description": "What stopped you, and what a person has to decide."}}}
}];
```

The object has only the keys `description`, the one-line meaning as above, and `data`, a mapping from
field names to field rules, as in `fields` of [Declaring data](#declaring-data). Both forms can be
mixed in one `Outcomes`. The prompt shows the `description` as the meaning.

### Declaring data

A step may say which fields it puts in `data` with `Data`. Its value has the shape of a pipeline's
[Input](#input): `fields`, each with its rules and a `description`, and optional JsonLogic `checks`.
The field rules are the same, and so is the rule that every field has a `description`:

```
Implement [Harness => Claude, Prompt => Implement_Task_Item, Data => {"fields": {
  "task_note": {"type": "string", "required": true, "description": "The task note's vault note name."},
  "remaining": {"type": "integer", "required": true, "description": "The number of unchecked items left."}
}}];
```

- A step's data is the next step's input. The next step is given the previous step's result, `data`
  included, and nothing else: no field is kept for the rest of the run. A value that several later
  steps need, such as the name of a task note, is declared in the `Data` of every step that hands it
  on.
- A step's data is its `Data` fields and the `data` fields of the outcome it ends with, merged.
  `Data` holds whatever the outcome; an outcome's `data` holds only with that outcome. A field another
  outcome declares is not part of it.
- A field is declared once per step: a name in both the step's `Data` and an outcome's `data` is an
  error.
- A step takes its own `Data`, else its system's, as it does `Outcomes`.
- The program writes the fields into the step's prompt, after the outcome words: "Put these fields in
  data:" with one line per field (its name, type, whether it is required, and its description), then
  "With <Word>, also put:" for each outcome that has `data`. So a prompt does not list what goes in
  `data` or tell the session to hand a field on.
- The answer's `data` is checked against the merged declaration. It is closed: a field the step does
  not declare is a problem, as is a missing required field or a value that breaks a rule. An answer
  with a problem is a `result_contract_failure` and is tried again as `Retries` says. The prompt of
  the next try starts its contract with "Your last answer was refused:" and one line per problem,
  such as `- data.remaining: required field is missing`.
- A step with neither `Data` nor an outcome with `data` has its `data` unchecked, as before.
- A guard of an edge that leaves a step that declares data may read only fields that step declares,
  in its `Data` or in one of its outcomes' `data`. `{"var": "data.blocker"}` on an edge from a step
  that declares no `blocker` is an error in the definition. A step that declares no data is not
  checked, and the prose of a prompt is never read for fields.

`show` reports a step's `Data` as `data`, and each outcome's fields with the outcome.

This is a whole pipeline written with `Data`. `task_note` and `design_note` are in the `Data` of every
step that hands them on, and the outcomes that hand on more say so in their own `data`:

```
-- Turn a Ready design note into a task note, then implement, review and finalize it.
Pipeline Build_Task [Description => "Compile a Ready design note, then implement, review and finalize it."] {
   Check_Ready [Harness => Claude, Permissions => Read_Only,
      Prompt => "Find the design note the input names, and say whether it is ready to build.",
      Outcomes => {
        "Ready": {"description": "Exactly one design note matches the input and its status is Ready.",
                  "data": {"design_note": {"type": "string", "required": true,
                                           "description": "The design note's vault note name."}}},
        "Not_Ready": {"description": "No design note matches, more than one does, or its status is not Ready.",
                      "data": {"reason": {"type": "string", "required": true,
                                          "description": "Which of these it is."},
                               "candidates": {"type": "list", "items": "string",
                                              "description": "The vault note names of near matches."}}}
      }];

   Compile [Harness => Claude, Prompt => "Compile the task note for the design note named by design_note.",
      Data => {"fields": {
        "task_note": {"type": "string", "required": true, "description": "The task note's vault note name."},
        "design_note": {"type": "string", "required": true, "description": "The design note's vault note name."},
        "tasks": {"type": "integer", "required": true, "description": "The number of checklist items."}
      }}];

   Implement [Harness => Claude, Retries => 1,
      Prompt => "Implement the next unchecked item of the task note named by task_note. Fix every problem in problems first.",
      Data => {"fields": {
        "task_note": {"type": "string", "required": true, "description": "The task note's vault note name."},
        "design_note": {"type": "string", "required": true, "description": "The design note's vault note name."},
        "remaining": {"type": "integer", "required": true, "description": "The number of unchecked items left."}
      }},
      Outcomes => {
        "More_Remaining": "The item is implemented, its tests pass and it is ticked, and at least one unchecked item remains.",
        "All_Implemented": "Every item is ticked and all the tests you ran pass.",
        "Blocked": {"description": "You could not finish the item. Nothing unverified was ticked.",
                    "data": {"blocker": {"type": "string", "required": true,
                                         "description": "What stopped you, and what a person has to decide."}}}
      }];

   Review [Harness => Claude, Permissions => Read_Only,
      Prompt => "Review the change against the task note named by task_note and its design note.",
      Data => {"fields": {
        "task_note": {"type": "string", "required": true, "description": "The task note's vault note name."},
        "design_note": {"type": "string", "required": true, "description": "The design note's vault note name."}
      }},
      Outcomes => {
        "Approved": "Every item is implemented, tested and ticked, and you found nothing to fix.",
        "Changes_Requested": {"description": "At least one item is missing, wrong, untested or outside the plan.",
                              "data": {"problems": {"type": "list", "required": true, "min_length": 1,
                                                    "description": "Each problem found.",
                                                    "items": {"fields": {
                                                      "file": {"type": "string", "required": true, "description": "The file the problem is in."},
                                                      "location": {"type": "string", "description": "Where in the file, such as a line or a function."},
                                                      "issue": {"type": "string", "required": true, "description": "What is wrong."}
                                                    }}}}}
      }];

   Finalize [Harness => Claude, Prompt => "Run the final checks of the task note named by task_note.",
      Data => {"fields": {
        "task_note": {"type": "string", "required": true, "description": "The task note's vault note name."},
        "design_note": {"type": "string", "required": true, "description": "The design note's vault note name."}
      }},
      Outcomes => {
        "In_Review": "Every final check passed and the task note's status is REVIEW.",
        "Checks_Failed": {"description": "At least one final check failed.",
                          "data": {"problems": {"type": "list", "required": true, "min_length": 1,
                                                "description": "Each failure.",
                                                "items": {"fields": {
                                                  "file": {"type": "string", "required": true, "description": "The file the failure points at."},
                                                  "location": {"type": "string", "description": "Where in the file, such as a line or a test name."},
                                                  "issue": {"type": "string", "required": true, "description": "What failed."}
                                                }}}}}
      }];

   Check_Ready -> End [When => Not_Ready];
   Implement -> Implement [When => More_Remaining, Max_Iterations => 100];
   Implement -> End [When => More_Remaining];
   Implement -> End [When => Blocked];
   Review -> Implement [When => Changes_Requested, Max_Iterations => 5];
   Review -> End [When => Changes_Requested];
   Finalize -> Implement [When => Checks_Failed, Max_Iterations => 3];
   Finalize -> End [When => Checks_Failed];
}
```

The prompts name fields ("the task note named by task_note") and do not explain them or say what to
put in `data`: the declarations do both. Implement is given whichever result came before it: from
Compile on the first visit, from itself, from Review with `problems`, or from Finalize with
`problems`. Each of those declares `task_note` and `design_note`, so the fields Implement needs are
always there.

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
| `result_contract_failure` | The session ended but its answer is not a valid result, its outcome is not one the step declares, or its `data` breaks the step's declared data. Retried as many times as `Retries` says, each try told what was wrong with the last. |
| `quota_exhausted` | The harness said a limit was reached. Never retried; the harness's reset time is reported when it gives one. |
| `ceiling_reached` | The run took `SYNAPSE_PIPELINE_MAX_STEPS` steps (default 50) without completing. |

## What is checked before anything runs

`synapse-pipeline check` and `synapse-pipeline run` check, before the first session starts:

- the grammar, with the file, line and column of every error;
- that every step, edge, system, agent and prompt that is named exists, and is of the right kind (an edge may also lead to `End`);
- that every step has a harness, a known permission level and a well-formed duration;
- that a system does not name a system;
- that every guard is a rule the evaluator can run, and every back-edge is bounded;
- that a step that declares `Outcomes` declares well (words and one-line meanings) and has no edge testing a word it does not declare;
- that a step's `Data` and its outcomes' `data` use only the known rules, give every field a `description`, and declare no field twice, and that a guard reads no data field the step it leaves does not declare;
- that a pipeline's `Input` uses only the known rules, gives every field a `description`, has well-formed patterns, and has checks the evaluator can run.

All the problems found are reported together.
