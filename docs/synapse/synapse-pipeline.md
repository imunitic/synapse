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
   run is complete. The agent never decides this: it reports what happened, and the guards route.
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
| `Workspace_Write` | edits are accepted; a command runs only if `Tools` allows it | `workspace-write` sandbox | files outside the working directory denied |
| `Full_Access` | no permission checks | `danger-full-access` sandbox | no restriction |

A session cannot ask anyone to approve anything, so a tool the level does not allow is refused
rather than waited for. OpenCode's restrictions apply to its file tools; a command it runs is not
confined to the working directory.

`Tools` is a list of tools the session may use. It is honoured by Claude. A step that sets it for
Codex or OpenCode fails before a session is started, because neither can restrict a session's tools.

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

`list` shows the runs that are going. A run that has ended, or that died without cleaning up, is not
shown. `info --format json` gives the answer as JSON, and `--query` takes a
[JsonLogic](https://jsonlogic.com) rule that the run evaluates over its brief (the members `info`
shows), its state under `state` and its events under `events`. A `var` path goes through objects only,
not into a list.

The run listens on a Unix domain socket at `$SYNAPSE_WORK_DIR/pipelines/<execution-id>.sock`, in a
directory only the user can enter, and removes it when it ends. A run without a work directory, or
whose socket cannot be made, is not inspectable and goes on exactly as it would have; the second case
is reported with one warning line when it starts. Inspecting is not available on Windows yet.

### The protocol

Another program can speak to a run directly. It sends one JSON request ended by a line feed (or by the
end of what it sends) and reads one JSON answer: `{"ok": true, "result": ...}` or
`{"ok": false, "error": "..."}`.

| Request | Answer |
|---|---|
| `{"command": "info"}` | execution id, pipeline, status, current step, steps run, failure |
| `{"command": "state"}` | the run's state |
| `{"command": "events", "after": 12}` | the events after sequence number 12 (all, without `after`) |
| `{"command": "query", "expression": <rule>}` | the rule evaluated as described above |

Events are `run.started`, `step.started`, `step.finished`, `run.completed` and `run.failed`, each with
a sequence number, the step and a detail object; the last 200 are kept. Any other command is an error.
A request over 4 KiB is refused and an answer over 1 MiB is replaced by an error. A client that
connects and says nothing is dropped after two seconds. A client that misbehaves, or an error in
serving one, never affects the run.

## Platforms

Running a harness and inspecting a run are not available on Windows yet.
