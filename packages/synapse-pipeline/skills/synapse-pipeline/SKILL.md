---
name: synapse-pipeline
description: "Craft, check and run synapse-pipeline pipelines: declarative multi-step agent workflows. Use when asked to design, write, fix or run a pipeline, or to turn a described workflow into pipeline, system and agent definition files."
---

# synapse-pipeline

`synapse-pipeline` runs a **pipeline**: a set of steps, each one non-interactive Claude Code, Codex CLI or OpenCode session, where a step's result decides which step runs next. A pipeline is written as small declarative definition files. Crafting one means turning a described workflow into those files, checking them, and handing them over.

Requires `synapse-pipeline` on `PATH`. Run `synapse-pipeline --help` first; if it is missing, say so and stop.

## Crafting a pipeline

1. **Pin down the workflow.** Ask only for what is missing: the steps and what each one does, which step decides to loop back and on what condition, what the first step is given, what the run should end with, and whether any step must be unable to change files. Do not invent requirements the user did not state.
2. **Look at what exists.** List `${XDG_CONFIG_HOME:-$HOME/.config}/synapse-pipeline/` (and any directory in `SYNAPSE_PIPELINE_PATH`). Every definition lives in one namespace shared by pipelines, systems and agents, so reuse an existing agent or system where it fits and never write a name that is taken. If a file you would write already exists, show the user and ask before replacing it.
3. **Write the definitions** into `${XDG_CONFIG_HOME:-$HOME/.config}/synapse-pipeline/`, one definition per file (see "Definitions"). **Write a single `Pipeline` file by default**, with each step's role and instructions in its own `Prompt`. Create an `Agent` or `System` file only when it is useful beyond this pipeline: the user says it will be reused, or an existing one already fits. A role used by one pipeline is the opening sentences of that step's `Prompt`, not a file.
4. **Check**: `synapse-pipeline check <Pipeline>`. It reports every problem with file, line and column. Fix them all and re-run until it exits 0.
5. **Review**: `synapse-pipeline show <Pipeline>` prints the steps with the settings each will run with (harness, permissions, timeout, role, assignment) and the edges. Read it against the workflow you were given and correct any difference.
6. **Try it without cost** when the user wants confidence before a real run: write an answers file and run with `SYNAPSE_PIPELINE_RUNNER=scripted SYNAPSE_PIPELINE_SCRIPT=<file>` (see "Trying a pipeline without agents").
7. **Hand it over**: name the files written, summarise the steps and loops in a few lines, and give the command to run it. **Do not run a real pipeline unless asked**: every step is a real agent session that costs money and can change files. When asked to run it, follow "Running and monitoring".

## Definitions

A definition file has the extension `.synapse` and holds exactly one definition. Its first word says the kind, and the file name without the extension must equal the name it declares (`Reviewer.synapse` declares `Agent Reviewer`). Comments run from `--` to the end of the line. Names are letters, digits and underscores starting with a letter, in `Pascal_Case` by convention.

| Kind | What it is |
|---|---|
| `Pipeline` | Steps and the edges between them. |
| `System` | A named, reusable partial step: the setup a session runs with. |
| `Agent` | A role: a `Prompt` or `Skill` saying who the session is. Independent of any harness. |

A pipeline that stands alone is one file, with the role at the start of each step's prompt:

```
-- Develop_Feature.synapse
Pipeline Develop_Feature {
   Develop [Harness => Claude, Prompt => "You are a careful engineer. Implement the supplied task and change nothing else. Report the outcome Done."];
   Review  [Harness => Codex, Permissions => Read_Only, Prompt => "You are a reviewer. Find what is wrong with the change; do not fix it. Report the outcome Approved, or Changes_Requested with the problems in data."];
   Review -> Develop [When => Changes_Requested, Max_Iterations => 5];
}
```

A pipeline that should stop when a condition is not met ends early by routing to `End`:

```
-- Ready_Gate.synapse
Pipeline Ready_Gate {
   Check [Harness => Claude, Permissions => Read_Only, Prompt => "Look at the design note. Report the outcome Ready if its status is Ready, otherwise Discussing."];
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
System Strict_Reviewer [Agent => Reviewer, Harness => Codex, Permissions => Read_Only, Prompt => "Review the change. Report Approved, or Changes_Requested with the problems in data."];
```

```
-- Review_Change.synapse
Pipeline Review_Change {
   Review [System => Strict_Reviewer];
}
```

- A pipeline body is steps (`Name [attributes];`) and edges (`From -> To [attributes];`, and `A -> B -> C` is one edge per pair). Steps run in declared order unless an edge redirects control. An edge to an undeclared step is an error.
- Attributes are comma-separated `Name => value` pairs and the list may be omitted. Strings are double-quoted with JSON escapes; `"""..."""` takes everything to the closing triple quote verbatim, for a multi-paragraph prompt. A `{` or `[` after `=>` starts a JSON value.
- Everything is referred to by name; there are no inline definitions. `Agent =>` takes an agent and `System =>` a system, and a system cannot name another system.

| Attribute | On | Value |
|---|---|---|
| `Agent` | step, system | agent name |
| `System` | step | system name |
| `Prompt` | step, system, agent | string (instructions inline) |
| `Skill` | step, system, agent | skill name (1-64 lowercase letters, digits, single hyphens) |
| `Harness` | step, system | `Claude`, `Codex` or `Opencode` |
| `Model` | step, system | name or string |
| `Permissions` | step, system | `Read_Only`, `Workspace_Write` (default) or `Full_Access` |
| `Tools` | step, system | JSON list of strings; only Claude honours it, the others fail the step |
| `Timeout` | step, system | quoted duration: `"90s"`, `"30m"`, `"2h"` (default 30 minutes) |
| `Retries` | step, system | integer: extra tries after an execution error or an invalid result |
| `When` | edge | outcome name, or a JsonLogic rule |
| `Max_Iterations` | edge | integer, at least 1 |

How a step is built: its own attributes override its system's; a `Prompt` or `Skill` on the step replaces the system's as a unit; the agent's `Prompt` or `Skill` is the **role** (who the session is) and the step's is the **assignment** (what to do). `Prompt` and `Skill` are alternatives on one node. A step with no harness of its own, from its system or from `SYNAPSE_PIPELINE_HARNESS`, is an error: always give a harness on the step or its system.

## Results and routing

Every step ends with one result, `{"outcome": "<Word>", "summary": "<text>", "data": {...}}`. `outcome` is a single word naming what happened, `summary` is for a person, `data` is an object (empty when nothing is handed on). Any other member makes the result invalid. The next step is given the pipeline's input and the previous step's result.

**The agent never picks the next step; guards on the outcome do.** So every step's prompt must state the exact outcome words it may report and when, using the same spelling as the `When` guards that route on them. A guard that names a word no step reports never fires. Say which fields `data` holds when a later step or guard reads them.

- `When => Changes_Requested` is shorthand for `{"==": [{"var": "outcome"}, "Changes_Requested"]}`.
- `When => {">": [{"var": "data.failing"}, 0]}` is a JsonLogic rule over `outcome`, `summary` and `data` only; a missing field reads as `null`; a `var` path follows object members, not list positions. It must give true or false.
- After a step, the edges leaving it are tried in written order and the first whose guard holds is taken. An edge with no `When` is always taken when reached. An edge that has fired `Max_Iterations` times is skipped. When none is taken, the next declared step runs; after the last, the run is complete.
- **To stop a run early, route to `End`**: `Check -> End [When => Discussing]` completes the run at once, successfully (exit code 0), with no session, and the run's result is the result of the step the edge leaves. `End` is not a step: it is reserved, so no step or definition can be called `End`, and nothing can leave it. Without an edge to `End`, a run only completes after its last step, and a step with no edge taken falls to the next declared step.
- **Every back-edge** (to an earlier step or to itself) **must have `Max_Iterations`.** A run is also held to 50 steps in all (`SYNAPSE_PIPELINE_MAX_STEPS`).
- A failed step ends the run; nothing in a pipeline catches a failure. Use `Retries` for steps that may time out or answer badly.

## Choosing settings

- Give a step the least it needs: `Read_Only` for review, analysis and anything that must not change files; `Workspace_Write` for steps that edit; `Full_Access` only when the user asks for it. A session cannot ask anyone to approve something, so what a level forbids is refused.
- Keep a setup inline in the step unless it is useful beyond this pipeline. Steps of one pipeline that need the same settings just repeat the attributes; a `System` or `Agent` is for what other pipelines will share.
- Set `Timeout` for steps that could run long and `Retries` for steps that can flake. Leave both out otherwise.
- Prefer a short inline `Prompt`. For a long or reusable instruction, use a `Skill`.

## Skills for steps

A pipeline step or agent can use `Skill => "name"`. The skill is a directory `<name>/` holding a `SKILL.md` (the [Agent Skills](https://agentskills.io) format: frontmatter with `name` equal to the directory name and a `description`, then the instructions), placed in `${XDG_CONFIG_HOME:-$HOME/.config}/synapse-pipeline/skills/`. Its text becomes part of the step's prompt, so no harness needs it installed. `check` fails if a named skill is missing and lists the directories it searched.

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

A run takes as long as its sessions do, often many minutes, so **run it as a background job** and watch it, instead of blocking on it. Use the host's own facility for a background command (in Claude Code, a Bash call with `run_in_background`).

1. **Make the run inspectable.** Set `SYNAPSE_WORK_DIR` for the job to an existing directory with a **short path**: the run listens on `$SYNAPSE_WORK_DIR/pipelines/<execution-id>.sock`, and a Unix socket path over 100 bytes cannot be made (a long scratch path gives "introspection is unavailable" on standard error, and the run goes on uninspectable). A directory made with `mktemp -d` under `/tmp` is short enough. Give the monitoring commands the same `SYNAPSE_WORK_DIR`. Inspection is not available on Windows.
2. **Find the run**: `synapse-pipeline list` prints one line per run in progress for that work directory: execution id, pipeline, status, current step.
3. **Ask it questions**; all of these only read, and nothing here can start, stop or change the run:
   - `synapse-pipeline info <id>` is the brief: status, current step, steps run, the failure if there is one.
   - `synapse-pipeline info <id> --query '<rule>'` evaluates a [JsonLogic](https://jsonlogic.com) rule over the run, and `--format json` gives structured output. A `var` path follows object members only, not positions in a list. What a rule can read: the brief's members (`status`, `current_step`, `steps_run`, `failure`), `state` (the whole state), `events` and `pipeline`.

| To learn | Query |
|---|---|
| which step is running | `{"var": "current_step"}` |
| what the last step reported | `{"var": "state.previous_output.outcome"}` and `{"var": "state.previous_output.summary"}` |
| what it handed on | `{"var": "state.previous_output.data"}` |
| how often each edge has fired | `{"var": "state.fired"}`: one count per edge in order, so entry *i* belongs to `pipeline.edges[i]` (the edge's `index`); a missing entry is 0 |
| the history | `{"var": "events"}`: the last 200 events, each with `sequence`, `kind` (`run.started`, `step.started`, `step.finished`, `run.completed`, `run.failed`), `step` and `detail` |
| what the pipeline is | `{"var": "pipeline"}`: the steps with their settings and the edges, as `show --format json` prints them |

4. **Report as it moves.** Steps take minutes, so check every little while, not in a tight loop, or wait for the host to say the background job finished. Tell the user in a sentence when the current step changes, and when a loop goes round again (an edge's count goes up), using `show` or `pipeline` to say what each step is.
5. **Read the end from the job.** Once a run ends it stops answering: `list` no longer shows it and `info <id>` says that no run is listening. The result is on the job's standard output, the per-step lines on its standard error, and the exit code says whether it completed. Report the final outcome and summary, or the failure line, to the user.

Stopping the background job stops the run, in the middle of a session if one is going; nothing in `synapse-pipeline` can stop it.

To run a pipeline inside the current session instead, with each step a subagent and no `synapse-pipeline run`, use the `synapse-pipeline-execute` skill. Its steps do not enforce `Permissions` or `Timeout`, so `run` is the way to hold a pipeline to its restrictions.

## Commands

- `synapse-pipeline check <pipeline>`: validate; nothing is run.
- `synapse-pipeline show <pipeline> [--format json|text]`: describe the steps, settings and edges.
- `synapse-pipeline next <pipeline> [--input <file>|-] | --state <file>|- --result <file>|-`: the state a run starts in, or the state after a step's result; for running a pipeline in a session (see `synapse-pipeline-execute`).
- `synapse-pipeline run <pipeline> [--input <file>|-]`: run it.
- `synapse-pipeline list`, `synapse-pipeline info <execution-id> [--format json|text] [--query <rule>]`: inspect runs in progress.
