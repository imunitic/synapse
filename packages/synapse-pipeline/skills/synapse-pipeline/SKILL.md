---
name: synapse-pipeline
description: "Craft, check and run synapse-pipeline pipelines: declarative multi-step agent workflows. Use when asked to design, write, fix or run a pipeline, or to turn a described workflow into pipeline, system, agent and prompt definition files."
---

# synapse-pipeline

`synapse-pipeline` runs a **pipeline**: a set of steps, each one non-interactive Claude Code, Codex CLI or OpenCode session, where a step's result decides which step runs next. A pipeline is written as small declarative definition files. Crafting one means turning a described workflow into those files, checking them, and handing them over.

Requires `synapse-pipeline` on `PATH`. Run `synapse-pipeline --help` first; if it is missing, say so and stop.

## Crafting a pipeline

1. **Pin down the workflow.** Ask only for what is missing: the steps and what each one does, which step decides to loop back and on what condition, what the first step is given, what the run should end with, and whether any step must be unable to change files. Do not invent requirements the user did not state.
2. **Look at what exists.** List `${XDG_CONFIG_HOME:-$HOME/.config}/synapse-pipeline/` (and any directory in `SYNAPSE_PIPELINE_PATH`). Every definition lives in one namespace shared by pipelines, systems, agents and prompts, so reuse an existing agent, system or prompt where it fits and never write a name that is taken. If a file you would write already exists, show the user and ask before replacing it.
3. **Write the definitions** into `${XDG_CONFIG_HOME:-$HOME/.config}/synapse-pipeline/`, one definition per file (see "Definitions"). **Write a single `Pipeline` file by default**, with each step's role and instructions in its own `Prompt`. Create an `Agent`, `System` or `Prompt` file only when it is useful beyond this pipeline: the user says it will be reused, or an existing one already fits. A role used by one pipeline is the opening sentences of that step's `Prompt`, not a file. Declare `Outcomes` on every step an edge tests, and `Data` on every step that hands data on, and keep the result format, the outcome words and the list of `data` fields out of the prompts (see "Results and routing" and "Declaring data").
4. **Check**: `synapse-pipeline check <Pipeline>`. It reports every problem with file, line and column. Fix them all and re-run until it exits 0. A warning that a step has edges testing its outcome but declares no `Outcomes` is not left as it is: add them.
5. **Review**: `synapse-pipeline show <Pipeline>` prints the steps with the settings each will run with (harness, permissions, timeout, role, assignment) and the edges. Read it against the workflow you were given and correct any difference.
6. **Try it without cost** when the user wants confidence before a real run: write an answers file and run with `SYNAPSE_PIPELINE_RUNNER=scripted SYNAPSE_PIPELINE_SCRIPT=<file>` (see "Trying a pipeline without agents").
7. **Hand it over**: name the files written, summarise the steps and loops in a few lines, and give the command to run it. **Do not run a real pipeline unless asked**: every step is a real agent session that costs money and can change files. When asked to run it, follow "Running and monitoring".

## Definitions

A definition file has the extension `.synapse` and holds exactly one definition. Its first word says the kind, and the file name without the extension must equal the name it declares (`Reviewer.synapse` declares `Agent Reviewer`). Comments run from `--` to the end of the line. Names are letters, digits and underscores starting with a letter, in `Pascal_Case` by convention.

| Kind | What it is |
|---|---|
| `Pipeline` | Steps and the edges between them. |
| `System` | A named, reusable partial step: the setup a session runs with. |
| `Agent` | A role: a `Prompt` saying who the session is. Independent of any harness. |
| `Prompt` | A named, reusable text of instructions, used with `Prompt => Name` on a step, a system or an agent. |

Every kind can have a `Description`, a short text for a person that list views show next to the name. It is never part of a session's prompt. A pipeline takes it in an optional attribute list before its body: `Pipeline Name [Description => "..."] { ... }`.

A pipeline that stands alone is one file, with the role at the start of each step's prompt:

```
-- Develop_Feature.synapse
Pipeline Develop_Feature {
   Develop [Harness => Claude, Prompt => "You are a careful engineer. Implement the supplied task and change nothing else."];
   Review  [Harness => Codex, Permissions => Read_Only, Prompt => "You are a reviewer. Find what is wrong with the change; do not fix it.",
            Outcomes => {"Approved": "Every requirement is met and the tests pass. Choose this only if you found nothing to fix.",
                         "Changes_Requested": {"description": "At least one requirement is unmet or a test fails.",
                                               "data": {"problems": {"type": "list", "items": "string", "required": true, "min_length": 1, "description": "Each problem found, one per item."}}}}];
   Review -> Develop [When => Changes_Requested, Max_Iterations => 5];
}
```

A pipeline that should stop when a condition is not met ends early by routing to `End`:

```
-- Ready_Gate.synapse
Pipeline Ready_Gate {
   Check [Harness => Claude, Permissions => Read_Only, Prompt => "Look at the design note and say whether it is ready to build.",
          Outcomes => {"Ready": "The note's status is Ready and its Open Questions section is empty.", "Discussing": "The status is anything other than Ready, or a question is still open."}];
   Build [Harness => Claude, Prompt => "Implement the design note."];
   Check -> End [When => Discussing];
}
```

An `Agent` or `System` is worth a file when other pipelines will use it. Here a reviewer is defined once and a pipeline uses it:

```
-- Reviewer.synapse
Agent Reviewer [Prompt => "You are a reviewer. Find what is wrong with the change; do not fix it."];
```

```
-- Strict_Reviewer.synapse
System Strict_Reviewer [Agent => Reviewer, Harness => Codex, Permissions => Read_Only, Prompt => "Review the change.",
                       Outcomes => {"Approved": "You found nothing to fix.",
                                    "Changes_Requested": {"description": "You found at least one problem.",
                                                          "data": {"problems": {"type": "list", "items": "string", "required": true, "min_length": 1, "description": "Each problem found, one per item."}}}}];
```

```
-- Review_Change.synapse
Pipeline Review_Change {
   Review [System => Strict_Reviewer];
}
```

- A pipeline body is steps (`Name [attributes];`) and edges (`From -> To [attributes];`, and `A -> B -> C` is one edge per pair). Steps run in declared order unless an edge redirects control. An edge to an undeclared step is an error.
- Attributes are comma-separated `Name => value` pairs and the list may be omitted. Strings are double-quoted with JSON escapes; `"""..."""` takes everything to the closing triple quote verbatim, for a multi-paragraph prompt. A `{` or `[` after `=>` starts a JSON value.
- Everything is referred to by name; there are no inline definitions. `Agent =>` takes an agent, `System =>` a system and `Prompt =>` a string or a prompt, and a system cannot name another system.

| Attribute | On | Value |
|---|---|---|
| `Agent` | step, system | agent name |
| `System` | step | system name |
| `Prompt` | step, system, agent | string (instructions inline), or the name of a `Prompt` definition |
| `Prompt` | prompt | string: the prompt's text |
| `Description` | pipeline, system, agent, prompt | string, for a person; never part of a prompt |
| `Input` | pipeline | JSON object declaring the input's fields, each with a description (see "Declaring the input") |
| `Harness` | step, system | `Claude`, `Codex` or `Opencode` |
| `Model` | step, system | name or string |
| `Permissions` | step, system | `Read_Only`, `Workspace_Write` (default) or `Full_Access` |
| `Timeout` | step, system | quoted duration: `"90s"`, `"30m"`, `"2h"` (default 30 minutes) |
| `Retries` | step, system | integer: extra tries after an execution error or an invalid result |
| `Outcomes` | step, system | JSON object from each outcome word to a one-line meaning, or to `{"description": <meaning>, "data": {<fields>}}` for an outcome that hands on data of its own; declare it on every step an edge guard tests (see below) |
| `Data` | step, system | JSON object declaring the fields the step puts in `data` whatever its outcome, each with a description (see "Declaring data") |
| `When` | edge | outcome name, or a JsonLogic rule |
| `Max_Iterations` | edge | integer, at least 1 |

How a step is built: its own attributes override its system's; a `Prompt` on the step replaces the system's, whether each is a text or a name; the agent's `Prompt` is the **role** (who the session is) and the step's is the **assignment** (what to do). A step with no harness of its own, from its system or from `SYNAPSE_PIPELINE_HARNESS`, is an error: always give a harness on the step or its system.

## Declaring the input

When a pipeline needs input, declare it with `Input` in the pipeline's attribute list, so the input is checked before anything runs and every step's prompt explains each field. The value is written in Synapse's schema language, the same one vault note schemas use: field rules, and JsonLogic `checks` for rules across fields:

```
-- Implement_Task_Note.synapse
Pipeline Implement_Task_Note [Input => {
  "fields": {
    "task_id": {"type": "string", "required": true,
                "pattern": "^[a-z][a-z0-9-]*-[0-9]{3,}$",
                "description": "The id of the Synapse Vault task note to implement, such as synapse-067."},
    "instructions": {"type": "string",
                     "description": "Extra requirements for this run only, in plain words."}
  }
}] {
   Implement [Harness => Claude, Prompt => "Implement the task note named by task_id. Treat instructions, when given, as part of the task."];
}
```

- `fields` maps each field name (lowercase letters, digits and underscores, starting with a letter) to its rules: `type` (`string`, `integer`, `boolean`, `timestamp` or `list`), `required`, `min_length`, `const`, `pattern`, `enum`, and a `description`, which every field must have. `mutable`, `format`, `timezone`, `update_on` and the type `any` are refused.
- A `list` gives its items with `items`: a type name, or `{"fields": {...}}` written with the same rules.
- `checks` (optional) is a list of JsonLogic rules over the fields, each with an optional `message`: `{"var": "task_id"}` reads a field.
- The input is closed: a field not declared is an error. An optional field given as `""` or `[]` counts as not given. With exactly one required `string` field, a plain JSON string fills it.

A bad input is refused with exit code 2 and every problem listed, by `run`, `next --input`, `check --input` and `show --step --input`. The program writes the input into each step's prompt as a list, each field with its value and its description. So **a prompt names a field ("the task note named by task_id") and does not explain the input**: the description is the one place that says what a field means. Check a sample input with `synapse-pipeline check <Pipeline> --input -`.

## Results and routing

Every step ends with one result, `{"outcome": "<Word>", "summary": "<text>", "data": {...}}`. `outcome` is a single word naming what happened, `summary` is for a person, `data` is an object (empty when nothing is handed on). Any other member makes the result invalid. The next step is given the pipeline's input and the previous step's result.

**The agent never picks the next step; guards on the outcome do.** So the words a step may report must match the words its `When` guards test, and a guard that names a word no step reports never fires. **Give every step whose outcome an edge tests `Outcomes`**, a JSON object from each word to a line saying what it means: the program then puts the words and meanings into the step's prompt itself, `check` rejects a guard that tests a word the step does not declare, and an answer with another word fails as a contract failure and is tried again as `Retries` says. Never write the words or the result format into the `Prompt` (not "Report exactly one outcome word: …"): the program adds the result format to every step's prompt, and the words too once `Outcomes` are declared, so repeating them only creates a second place that can drift. A prompt need not name the words, so one `Prompt` definition can serve pipelines that use different words. A word is a letter, then letters, digits and underscores. The meaning is the only guidance the session gets on when to choose the word, so write the condition for choosing it, not a restatement of the word (not `Done: It is done.`), and declare what `data` holds instead of describing it (see "Declaring data"). A step takes its own `Outcomes`, else its system's; an agent has none. `Outcomes` is optional, but use it on every step whose outcome an edge tests: `check` warns when a step has such edges and declares none. Without `Outcomes` the outcome is any word, and the step's prompt must state the exact words it may report and when, spelled as in the `When` guards.

- `When => Changes_Requested` is shorthand for `{"==": [{"var": "outcome"}, "Changes_Requested"]}`.
- `When => {">": [{"var": "data.failing"}, 0]}` is a JsonLogic rule over `outcome`, `summary` and `data` only; a missing field reads as `null`; a `var` path follows object members, not list positions. It must give true or false.
- After a step, the edges leaving it are tried in written order and the first whose guard holds is taken. An edge with no `When` is always taken when reached. An edge that has fired `Max_Iterations` times is skipped. When none is taken, the next declared step runs; after the last, the run is complete.
- **To stop a run early, route to `End`**: `Check -> End [When => Discussing]` completes the run at once, successfully (exit code 0), with no session, and the run's result is the result of the step the edge leaves. `End` is not a step: it is reserved, so no step or definition can be called `End`, and nothing can leave it. Without an edge to `End`, a run only completes after its last step, and a step with no edge taken falls to the next declared step.
- **Every back-edge** (to an earlier step or to itself) **must have `Max_Iterations`.** A run is also held to 50 steps in all (`SYNAPSE_PIPELINE_MAX_STEPS`).
- A failed step ends the run; nothing in a pipeline catches a failure. Use `Retries` for steps that may time out or answer badly.

## Declaring data

**A step's data is the next step's input.** The next step is given the previous step's result and nothing else; no field is kept for the rest of the run. So declare, on every step that hands data on, the fields it puts in `data`, with `Data` in the shape of `Input` (`fields`, each with its rules and a `description`, and optional `checks`):

```
Implement [Harness => Claude, Prompt => "Implement the next unchecked item of the task note named by task_note.",
   Data => {"fields": {
     "task_note": {"type": "string", "required": true, "description": "The task note's vault note name."},
     "remaining": {"type": "integer", "required": true, "description": "The number of unchecked items left."}
   }},
   Outcomes => {"Done": "Every item is ticked.",
                "More_Remaining": "At least one unchecked item remains.",
                "Blocked": {"description": "You could not finish the item.",
                            "data": {"blocker": {"type": "string", "required": true, "description": "What stopped you."}}}}];
```

- `Data` holds whatever the outcome; an outcome's `data` (a bare field mapping) holds only with that outcome. The step's data is the two merged, and a field is declared once per step: not in both.
- **A value later steps need, such as `task_note`, is in the `Data` of every step that hands it on.** Never write "carry data.x forward" or a list of `data` fields into a prompt: the program writes the declared fields into the prompt itself, each with its type, whether it is required and its description.
- The answer's `data` is checked: a missing required field, a field not declared, or a value that breaks a rule is a contract failure, tried again under `Retries` with a prompt that names each problem. A step with no `Data` and no outcome `data` is not checked.
- A guard leaving a step that declares data may read only the fields that step declares: `check` refuses `{"var": "data.x"}` when `x` is not declared there.
- A step takes its own `Data`, else its system's. `show` lists the fields, and `show <Pipeline> --step <Step>` shows the prompt with them.

## Choosing settings

- Give a step the least it needs: `Read_Only` for review, analysis and anything that must not change files; `Workspace_Write` for steps that edit; `Full_Access` only when the user asks for it. A session cannot ask anyone to approve something, so what a level forbids is refused.
- Keep a setup inline in the step unless it is useful beyond this pipeline. Steps of one pipeline that need the same settings just repeat the attributes; a `System` or `Agent` is for what other pipelines will share.
- Set `Timeout` for steps that could run long and `Retries` for steps that can flake. Leave both out otherwise.
- Prefer a short inline `Prompt`. For a long or reusable instruction, write a `Prompt` definition.

## Reusable prompts

A step, a system or an agent can use `Prompt => Name` to take its instructions from a `Prompt` definition, a file of its own in the same directory as the other definitions:

```
-- Review_Code.synapse
Prompt Review_Code [Description => "Review a change against its task.", Prompt => """
Read the change and the task it was made for, and find every problem in it.
"""];
```

Its text becomes part of the step's prompt, as an inline string would; no harness needs anything installed. A prompt is text only: files next to it have no place in it. A step that needs files names their location in its prompt and gets access to them through its `Permissions`. `check` fails if a named prompt does not exist or is another kind, and lists the prompts a pipeline uses with their files.

## Trying a pipeline without agents

The scripted runner answers each step from a JSON file that maps a step name to its answers, used in order across tries and loop trips:

```json
{
  "Develop": [{"outcome": "Done", "summary": "built it", "data": {}}],
  "Review":  [{"outcome": "Changes_Requested", "summary": "one issue", "data": {}},
              {"outcome": "Approved", "summary": "looks good", "data": {}}]
}
```

```sh
SYNAPSE_PIPELINE_RUNNER=scripted SYNAPSE_PIPELINE_SCRIPT=answers.json synapse-pipeline run Develop_Feature
```

An answer may instead be a failure, `{"fail": "timeout"}` (also `execution_error`, `result_contract_failure`, `quota_exhausted`). A step with no answer left fails the run. Use this to exercise the loops and guards you wrote; it proves the routing, not the prompts.

## Running and monitoring

`synapse-pipeline run <Pipeline> [--input <file>|-]` runs the pipeline from its first step in the current directory. It prints one line per finished step to standard error and the last step's result as JSON to standard output; the exit code is 0 when the run completes and 1 when a step fails (the line `error: step <name> failed: <kind>: <message>` says why).

`--interactive` runs each step's harness on the terminal of the command, for a person who wants to watch and answer it; it is not for a background job or any other run with no terminal. `synapse-pipeline check <Pipeline> --interactive` says whether every step's harness can. While such a run goes on, `info` has an `attention` member: `state` is `waiting` when the agent has handed control to a person, with what it said as `reason`, and `running` otherwise.

A run takes as long as its sessions do, often many minutes, so **run it as a background job** and watch it, instead of blocking on it. Use the host's own facility for a background command (in Claude Code, a Bash call with `run_in_background`).

1. **Make the run inspectable.** Runs are recorded under the work directory, `~/.cache/synapse/work` unless `SYNAPSE_WORK_DIR` names another, and that is fine as it is. Set `SYNAPSE_WORK_DIR` for the job only when you want the records kept apart, and give the monitoring commands the same work directory (the default is the same every time). The run listens on `$SYNAPSE_WORK_DIR/pipelines/<execution-id>/execution.sock`, or, when that path is over 100 bytes, on a socket in `/tmp/synapse-pipeline-<uid>/`; the monitoring commands find either. On Windows the run listens on a named pipe.
2. **Find the run**: `synapse-pipeline list` prints one line per run in progress for that work directory: execution id, pipeline, status, current step. `list --all` adds the executions that are over (completed, failed, or interrupted when a record says running and nothing answers). `synapse-pipeline cleanup` removes old records: those of executions that are not running and were last written over 30 days ago (`--older-than`, `--dry-run` and `--all` change that).
3. **Ask it questions**; all of these only read, and nothing here can start, stop or change the run:
   - `synapse-pipeline info <id>` is the brief: status, current step, steps run, the failure if there is one. For an execution that is over it reads the record kept in `$SYNAPSE_WORK_DIR/pipelines/<id>/`, and `info <id> --events` prints the events recorded for it.
   - `synapse-pipeline info <id> --query '<rule>'` evaluates a [JsonLogic](https://jsonlogic.com) rule over the run, and `--format json` gives structured output. A `var` path follows object members only, not positions in a list. What a rule can read: the brief's members (`status`, `current_step`, `steps_run`, `failure`, and `attention` for an interactive run), `state` (the whole state), `events` and `pipeline`.

| To learn | Query |
|---|---|
| which step is running | `{"var": "current_step"}` |
| what the last step reported | `{"var": "state.previous_output.outcome"}` and `{"var": "state.previous_output.summary"}` |
| what it handed on | `{"var": "state.previous_output.data"}` |
| how often each edge has fired | `{"var": "state.fired"}`: one count per edge in order, so entry *i* belongs to `pipeline.edges[i]` (the edge's `index`); a missing entry is 0 |
| the history | `{"var": "events"}`: the last 200 events, each with `sequence`, `kind` (`run.started`, `step.started`, `session.waiting`, `session.resumed`, `session.finished`, `step.finished`, `run.completed`, `run.failed`), `step` and `detail` |
| what the pipeline is | `{"var": "pipeline"}`: the steps with their settings and the edges, as `show --format json` prints them |

4. **Report as it moves.** Steps take minutes, so check every little while, not in a tight loop, or wait for the host to say the background job finished. Tell the user in a sentence when the current step changes, and when a loop goes round again (an edge's count goes up), using `show` or `pipeline` to say what each step is.
5. **Read the end from the job.** Once a run ends it stops answering: `list` no longer shows it and `info <id>` says that no run is listening. The result is on the job's standard output, the per-step lines on its standard error, and the exit code says whether it completed. Report the final outcome and summary, or the failure line, to the user.

Stopping the background job stops the run, in the middle of a session if one is going; nothing in `synapse-pipeline` can stop it.

To run a pipeline inside the current session instead, with each step a subagent and no `synapse-pipeline run`, use the `synapse-pipeline-execute` skill. Its steps do not enforce `Permissions` or `Timeout`, so `run` is the way to hold a pipeline to its restrictions.

## Commands

- `synapse-pipeline check <pipeline> [--interactive] [--input <file>|-]`: validate; nothing is run. With `--interactive`, also check that every step's harness can run a step interactively. With `--input`, also check that input against the pipeline's `Input` (exit code 2 and every problem when refused).
- `synapse-pipeline show <name> [--format json|text] [--step <step> [--input <file>|-]]`: describe a pipeline's steps, settings and edges, or a system, an agent or a prompt with the definitions that use it; with `--step`, print the prompt that step is started with.
- `synapse-pipeline definitions [--format json|text]`: every pipeline, system, agent and prompt there is, with its file and description, and the files that did not load.
- `synapse-pipeline next <pipeline> [--input <file>|-] | --state <file>|- --result <file>|-`: the state a run starts in, or the state after a step's result; for running a pipeline in a session (see `synapse-pipeline-execute`).
- `synapse-pipeline run <pipeline> [--input <file>|-] [--id <execution-id>] [--interactive]`: run it; `--id` names the execution instead of drawing an id; `--interactive` runs each step's harness on the terminal.
- `synapse-pipeline list`, `synapse-pipeline info <execution-id> [--format json|text] [--query <rule>]`: inspect runs in progress.
