# Synapse Pipeline

`synapse-pipeline` runs **agent pipelines**: a set of steps, written in a small declarative language,
where every step is one non-interactive session of a coding agent (Claude Code, Codex CLI or OpenCode)
and a step's result decides which step runs next. A review that sends work back to development is a
pipeline; so is a chain of "write it, test it, document it".

It is a separate program from `synapse` and does not use the Vault or the Graph. Definitions are plain
files, a run keeps its state in memory while it goes, and nothing is written to disk. (Not to be
confused with the code-graph build in [synapse-graph.md](synapse-graph.md), which is also a sequence
of steps but is run by `synapse` and a model, not by this program.)

The language is described in [synapse-pipeline-language.md](synapse-pipeline-language.md) and every
command's options in [cli.md](cli.md).

## Install

```sh
npm install -g @imunitic/synapse-pipeline
```

The package depends on a package per platform (`@imunitic/synapse-pipeline-darwin-arm64` and so on)
that npm picks for the machine, so there is nothing to build or download afterwards. The harnesses a
pipeline uses are installed separately and must be on `PATH` when it runs.

### The skill for writing pipelines

The package also carries a skill that teaches an agent the definition language and the workflow of
writing a pipeline: ask for what is missing, write the pipeline, system and agent files into
`~/.config/synapse-pipeline/`, run `check` and `show`, and hand them over without running anything.
Install it for a harness with

```sh
synapse-pipeline-setup configure claude     # or codex, or opencode
```

and then ask the agent to craft a pipeline for a workflow. The skill goes to the harness's skills
directory (`~/.claude/skills`, `~/.codex/skills`, `~/.config/opencode/skill`) and only ever replaces or
removes what an earlier `synapse-pipeline-setup` put there.

## A first run

Put the definitions in `~/.config/synapse-pipeline/` (or any directory listed in
`SYNAPSE_PIPELINE_PATH`). `Develop_Feature.synapse`:

```
Pipeline Develop_Feature {
   Develop [Harness => Claude, Prompt => "Implement the supplied task."];
   Review  [Harness => Codex, Permissions => Read_Only, Prompt => "Review the change."];
   Review -> Develop [When => Changes_Requested, Max_Iterations => 5];
}
```

```sh
synapse-pipeline check Develop_Feature      # validate it; nothing is run
synapse-pipeline show Develop_Feature       # describe its steps, settings and edges
echo '{"task": "add a --verbose flag"}' | synapse-pipeline run Develop_Feature --input -
```

`run` prints one line per step to standard error as it finishes, and the last step's result as JSON to
standard output:

```
step Develop: Done -> Review
step Review: Changes_Requested -> Develop
step Develop: Done -> Review
step Review: Approved -> done
{"outcome":"Approved","summary":"Looks good.","data":{}}
```

The exit code is 0 when the run completes, 1 when a step fails or the pipeline cannot be run, and 2
for a usage error.

## What a run does

1. **Resolve.** The configuration and the pipeline, with every system, agent and skill it names, are
   resolved once, before the first session. The run uses that for its whole life, so editing a
   definition, a configuration or the vault directory while it goes changes nothing for it.
2. **Run the first step.** A session of the step's harness is started with a prompt made of the
   agent's role, the step's instructions, the pipeline's input, the previous step's result, and the
   contract for the answer. See [Harnesses](#harnesses).
3. **Check the answer.** It must be one JSON object `{"outcome", "summary", "data"}`. An answer that
   is not is a `result_contract_failure`.
4. **Choose the next step.** The edges leaving the step are tried in the order they were written; the
   first whose guard holds is taken. When none is, the next declared step runs, and after the last the
   run is complete, as it is when an edge leads to `End`. The agent never decides this: it reports what
   happened, and the guards route.
5. **Repeat** until the run completes or a step fails.

A step that fails ends the run, except that `Retries` gives an `execution_error` or a
`result_contract_failure` more tries. A `quota_exhausted` is never retried. A run is held to
`SYNAPSE_PIPELINE_MAX_STEPS` steps in all, which catches a loop that never ends. The failures are
listed in [the language reference](synapse-pipeline-language.md#failures).

A failed run prints
`error: step <name> failed: <kind>: <message>` and, for a quota, when the harness says it resets.
Steps run one at a time, and a run uses the working directory it was started in.

## Configuration

Everything is read from the environment when a run starts.

| Variable | Meaning | Default |
|---|---|---|
| `SYNAPSE_PIPELINE_PATH` | Directories of `.synapse` files, besides the default directory. | |
| `SYNAPSE_PIPELINE_HARNESS` | The harness of a step that names none: `Claude`, `Codex` or `Opencode`. | |
| `SYNAPSE_PIPELINE_TIMEOUT` | The time limit of a session whose step has no `Timeout`, such as `90s` or `30m`. | `30m` |
| `SYNAPSE_PIPELINE_MAX_STEPS` | The most steps one run may take. | `50` |
| `SYNAPSE_PIPELINE_RUNNER` | `process` runs the harnesses; `scripted` answers from a file. | `process` |
| `SYNAPSE_PIPELINE_SCRIPT` | The file a scripted run answers from. | |
| `SYNAPSE_WORK_DIR` | Where a running pipeline can be inspected from. Also given to every session. | |
| `SYNAPSE_VAULT_DIR`, `SYNAPSE_CONTENT_ROOT` | Given to every session, so that it works in the same vault. | |

`run` rejects a value that is wrong before it does anything, and says which variable it came from. Each of
the three `SYNAPSE_*` settings given to sessions is the variable of that name, else the setting
Synapse's own configuration files give (see [synapse-config.md](synapse-config.md)).

## Harnesses

A session is the harness's own program, run headless in the working directory the run was started in,
with the variables above added to its environment and held to the session's time limit. When the limit
passes the program and everything it started are stopped. The program is looked up on `PATH` when its
step starts, so a harness that is not installed fails that step and names the harness.

| Harness | Program | The answer is |
|---|---|---|
| `Claude` | `claude -p`, given the result schema | the structured output Claude returns |
| `Codex` | `codex exec --json` | the last message the agent wrote |
| `Opencode` | `opencode run --standalone --format json` | the text of the last message |

Every answer is checked against the result schema here as well, whatever the harness checked. An
answer wrapped in a code fence is accepted with the fence removed.

### Permissions

`Permissions` has three levels and is enforced by the harness, not by this program. A step with none
is `Workspace_Write`.

| Level | Claude | Codex | OpenCode |
|---|---|---|---|
| `Read_Only` | only the tools that read; nothing else is asked about or run | `read-only` sandbox | editing, commands and fetching denied |
| `Workspace_Write` | Claude's `auto` mode: edits and ordinary commands go ahead and what it refuses is for Claude to decide | `workspace-write` sandbox | files outside the working directory denied |
| `Full_Access` | no permission checks | `danger-full-access` sandbox | no restriction |

A session cannot ask anyone to approve anything, so a tool the level does not allow is refused
rather than waited for. OpenCode's restrictions apply to its file tools; a command it runs is not
confined to the working directory.

### Quota

A harness that reports that a limit or quota was reached fails the step as `quota_exhausted`, with
the time the limit resets when the harness says it. This is recognised from the wording the harness
uses ("usage limit", "rate limit", "hit your limit", "quota", "too many requests"); a harness that
words it differently is reported as an `execution_error`.

### Skills

The text of a step's skill is placed in the prompt, so no harness needs the skill installed, and the
prompt says which directory the skill's other files are in. Claude is also given that directory to
read.

## Running without a harness

`SYNAPSE_PIPELINE_RUNNER=scripted` answers every session from a JSON file instead of starting a
harness, so a pipeline can be tried with no agent installed and no cost. The file maps a step name to
its answers, used in order across the step's tries and its trips round a loop:

```json
{
  "Develop": [{"outcome": "Done", "summary": "built it", "data": {}},
              {"outcome": "Done", "summary": "fixed it", "data": {}}],
  "Review":  [{"outcome": "Changes_Requested", "summary": "one issue", "data": {}},
              {"outcome": "Approved", "summary": "looks good", "data": {}}]
}
```

An answer is a result, checked as every result is, or a failure: `{"fail": "timeout"}` (also
`execution_error`, `result_contract_failure` and `quota_exhausted`), with an optional `"message"` and,
for a quota, `"reset"`. Any answer may have `"delay_seconds"`, from 0 to 3600, which is how long the
session takes before it answers; it lets a run be watched from outside. A step with no answer left
fails the run.

The definitions are the same ones, with the same checks, whichever runner runs them.

## Running in a session

`run` starts a headless session of a harness for every step. A pipeline can instead be run by an
agent that is already in a session, with each step a subagent of that agent and no session of the
binary at all. `synapse-pipeline next` is what keeps the routing the same: it holds no process, takes
the run's state and a step's result, and prints the state that follows.

```sh
synapse-pipeline next Develop_Feature --input input.json > state.json     # a run's first state
synapse-pipeline next Develop_Feature --state state.json --result result.json > next.json
```

The state is the document `state` answers with over the socket (`synapse-pipeline-state/v1`), and
`status` says whether the run is going, completed or failed. The result is the object
`{"outcome", "summary", "data"}` a step ends with. `next` checks the result as `run` does, applies the
edges, guards, `Max_Iterations` and the step ceiling exactly as `run` does, and exits 0 whenever it
prints a state, so a failed run is a state with `status` `failed`. A result that is not valid, or a
state of another pipeline or of a run that is over, prints nothing and exits 1.

The `synapse-pipeline-execute` skill, installed by `synapse-pipeline-setup configure <harness>` with
the skill for writing pipelines, tells the agent to do this: one fresh subagent per step, with the
role, the assignment, the input and the previous result in its prompt, and `next` between steps. In
that mode `Harness` is ignored and `Permissions`, `Timeout` and `Retries` are advice to the subagent
and not enforced; `run` is the way to hold a pipeline to its restrictions.

## Inspecting a run

While a run goes, it can be asked about itself from another process. It is read-only: nothing can be
started, stopped or changed this way.

```sh
$ synapse-pipeline list
EXECUTION      PIPELINE         STATUS   STEP
exec-13a7d7cb  Develop_Feature  running  Review

$ synapse-pipeline info exec-13a7d7cb
execution  exec-13a7d7cb
pipeline   Develop_Feature
status     running
step       Review
steps run  1

$ synapse-pipeline info exec-13a7d7cb --query '{"var": "current_step"}'
Review
```

`show` describes a pipeline that is not running, with the document a run answers `pipeline` with:
`show Develop_Feature --format json` prints it as JSON, and without `--format` the same information is
laid out for a person. The pipeline is found and validated as `check` does, and one that cannot run
prints nothing on standard output.

`list` shows the runs that are going. A run that has ended, or that died without cleaning up, is not
shown. `info --format json` gives the answer as JSON, and `--query` takes a
[JsonLogic](https://jsonlogic.com) rule that the run evaluates over its brief (the members `info`
shows), its state under `state` and its events under `events`. A `var` path goes through objects only,
not into a list.

The run listens on a Unix domain socket at `$SYNAPSE_WORK_DIR/pipelines/<execution-id>/execution.sock`, in
the directory of its record, which only the user can enter, and removes the socket when it ends. A run without a work directory, or
whose socket cannot be made, is not inspectable and goes on exactly as it would have; the second case
is reported with one warning line when it starts. On Windows the run listens on a named pipe instead; see
Platforms.

### The record of a run

Each execution keeps a record in a directory of its own, `$SYNAPSE_WORK_DIR/pipelines/<execution-id>/`,
which only the user can enter and which stays after the run has ended:

```
execution.sock      only while the run is going
execution.json      the summary, replaced as the run goes on
events.jsonl        one event a line, as the socket gives them
description.json    the pipeline the run began with, as the socket answers `pipeline`
definitions/        the definition files the run was made from, laid out as a configuration directory
  synapse-pipeline/
    Develop_Feature.synapse    the pipeline, and every system and agent a step was built from
    skills/review-code/SKILL.md    the SKILL.md of each skill a step names
transcripts/
  1-Develop-1.jsonl   what a harness printed for one step attempt, as it printed it
  2-Review-1.jsonl
```

`execution.json` has `format` `synapse-pipeline-execution/v1`, the execution's `id` and `pipeline`, when it
`started` and `ended`, its `status` (`running`, `completed` or `failed`), its `current_step` and the run's
`state`. Each try of a step has a transcript of its own, named for the run's step count, the step and the try, and a
`session.finished` event that says where it is. For Claude the transcript is the final result the harness
prints, not the conversation.

`description.json` is the `synapse-pipeline-description/v1` document that `show --format json` prints, as the
run resolved it when it began: its steps and edges with the harness, permissions and timeout each step runs with,
and the limits. `definitions/` holds the files as they were when the run began, so editing or removing a
definition afterwards does not change what the record says. A file that cannot be read when the run begins is
left out. `XDG_CONFIG_HOME=<record>/definitions synapse-pipeline check <pipeline>`, with `SYNAPSE_PIPELINE_PATH`
unset, resolves the pipeline from those files; what comes from the environment, such as the default harness and
the limits, is the environment's of the moment, and `description.json` is what the run had.

These copies are history. Nothing runs from them: `run` resolves a pipeline from the definition directories as
they are when it starts, so running a pipeline again runs the files as they are then, not the ones an earlier
record kept.

- `list --all` lists the executions that are over as well, with the status they ended in. One whose record
  says `running` while nothing answers on its socket is shown as `interrupted`, and one with no summary as
  `incomplete`.
- `info <execution-id>` reads the record when nothing answers, and `info <execution-id> --events` prints the
  events recorded for it. A `--query` needs a run that is listening.
- `cleanup` removes the records of executions that are not running and were last written more than 30 days
  ago; `--older-than 90d` (a number and `d`, `h`, `m` or `s`) changes the age, `--dry-run` says what would
  go, and `--all` also removes every execution that completed or failed, whatever its age. An execution that
  answers on its socket is never removed, and one with no summary to date it by is kept.

The record is best effort. A write that fails is tried again up to five times with a short pause, and then
given up with one warning line for the execution; the run goes on, and its outcome and exit code are the
same as when everything is written. A record can therefore be incomplete, and every command that reads one
says so and does not fail.

### The protocol

Another program can speak to a run directly. It sends one JSON request ended by a line feed (or by the
end of what it sends) and reads one JSON answer: `{"ok": true, "result": ...}` or
`{"ok": false, "error": "..."}`.

| Request | Answer |
|---|---|
| `{"command": "info"}` | execution id, pipeline, status, current step, steps run, failure |
| `{"command": "state"}` | the run's state |
| `{"command": "pipeline"}` | the pipeline the run executes: its steps, edges and limits |
| `{"command": "events", "after": 12}` | the events after sequence number 12 (all, without `after`) |
| `{"command": "query", "expression": <rule>}` | the rule evaluated as described above |

The pipeline is described by one document, `synapse-pipeline-description/v1`, which is what the run
resolved when it started, so it is right even if a definition file is edited later. Its members are
fixed names, and a change to them is a new format.

| Member | Content |
|---|---|
| `format` | `synapse-pipeline-description/v1` |
| `name` | the pipeline's name |
| `steps` | in the order declared: `name`, `harness`, `model`, `permissions` (the level in effect), `timeout_seconds` (the limit in effect), `retries`, `role`, `assignment`, `origins` |
| `edges` | in the order declared: `index`, `from`, `to`, `guard` (a JsonLogic rule; null when unconditional), `max_iterations` (null when unbounded) |
| `limits` | `default_timeout_seconds`, `step_ceiling`, `runner` |

`role` and `assignment` are `{"kind": "prompt", "text": ...}`, `{"kind": "skill", "name": ...}` or null;
a skill is described by its name. `origins` lists the system and the agent a step was built from, each
with `kind`, `name` and `file`. An edge's `index` counts from 0 and is its position in `state.fired`.
The configuration's environment values are not part of it.

Events are `run.started`, `step.started`, `session.finished`, `step.finished`, `run.completed` and `run.failed`, each with
a sequence number, the step and a detail object; the last 200 are kept. Any other command is an error.
A request over 4 KiB is refused and an answer over 1 MiB is replaced by an error. A client that
connects and says nothing is dropped after two seconds. A client that misbehaves, or an error in
serving one, never affects the run.

## Platforms

What differs on Windows:

- A session's program is looked up on `PATH` with the extensions in `PATHEXT`, and a `.cmd` or `.bat` file is
  run through `cmd.exe` with its arguments quoted. A program and everything it starts are one job, which is
  stopped as a whole at the time limit.
- A run listens on a named pipe, `\\.\pipe\synapse-pipeline-<execution-id>`, in place of a socket. `list`,
  `info` and `cleanup` find and ask it as they do a socket. The pipe refuses clients on other machines but has
  the default access of a pipe, so another user of the same machine can ask a run what it is doing.
- Every execution directory is made, but the access mode of a directory is not changed.
