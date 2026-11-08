--  What `synapse-pipeline` says about itself, one text for every entry point,
--  so that a table cannot describe a subcommand differently from the usage a
--  person reads. Each subcommand has a help text whose first line is its
--  synopsis; a usage error prints only that line and `--help` prints it all.

package Synapse.Pipeline.Commands.Usage is

   LF : constant Character := Character'Val (10);

   --  The subcommand listing.
   Text : constant String :=
     "usage: synapse-pipeline <subcommand> [args]" & LF & LF
     & "  check <pipeline>   validate a pipeline and show what it would run"
     & LF
     & "  show <name> [--format json|text] [--step <step> [--input <file>|-]]"
     & LF
     & "         describe a pipeline (its steps, settings, edges and limits), "
     & "a system or an agent" & LF
     & "  definitions [--format json|text]" & LF
     & "         every pipeline, system and agent there is, and what is wrong "
     & "with a file" & LF
     & "  next <pipeline> [--input <file>|-] | --state <file>|- --result "
     & "<file>|-" & LF
     & "         the state a run starts in, or the state after a step's "
     & "result" & LF
     & "  run <pipeline> [--input <file>|-] [--id <execution-id>]" & LF
     & "         run a pipeline to its end" & LF
     & "  list [--all]   the pipelines running now, or all that were run" & LF
     & "  info <execution-id> [--format json|text] [--query <rule>] | "
     & "--events" & LF
     & "         what a pipeline says about itself, running or not" & LF
     & "  cleanup [--older-than <duration>] [--dry-run] [--all]" & LF
     & "         remove the records of executions that are over" & LF
     & "  configure <claude|codex|opencode>" & LF
     & "         install the skills of this program for a harness" & LF & LF
     & "'synapse-pipeline <subcommand> --help' says more." & LF
     & "'synapse-pipeline --version' says which version this is." & LF;

   Check_Help : constant String :=
     "usage: synapse-pipeline check <pipeline>" & LF & LF
     & "Loads every definition, validates the pipeline and everything it "
     & "refers to," & LF
     & "and prints its file and each step with its harness, and the files its "
     & "system" & LF
     & "and agent came from and the directory its skill was found in. Nothing "
     & "is run and" & LF
     & "no harness is needed. Every problem is reported on standard error "
     & "with its file," & LF
     & "line and column, and the exit code is 1. A definition that is "
     & "broken but not" & LF
     & "used by this pipeline is only a warning." & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_PIPELINE_PATH     directories of .synapse files besides "
     & "the default," & LF
     & "                            separated as the directories of a PATH "
     & "are" & LF
     & "  SYNAPSE_PIPELINE_HARNESS  the harness of a step that names none: "
     & "Claude, Codex" & LF
     & "                            or Opencode" & LF;

   Show_Help : constant String :=
     "usage: synapse-pipeline show <name> [--format json|text] "
     & "[--step <step> [--input <file>|-]]" & LF & LF
     & "Describes a pipeline that is not running the way a running one "
     & "describes itself:" & LF
     & "its steps with the settings each will run with, the edges between "
     & "them and" & LF
     & "the limits that apply. The pipeline is found and validated as "
     & "'check' does, and" & LF
     & "nothing is printed on standard output when it cannot be run." & LF & LF
     & "A system or an agent is described by its attributes as written, its "
     & "file and the" & LF
     & "definitions that use it." & LF & LF
     & "  --format text   for a person (the default)" & LF
     & "  --format json   for a pipeline the document a running pipeline "
     & "answers its" & LF
     & "                  'pipeline' command with, format "
     & "synapse-pipeline-description/v1," & LF
     & "                  plus its kind, file and an empty used_by; for a "
     & "system or an" & LF
     & "                  agent format synapse-pipeline-definition/v1" & LF
     & "  --step <step>   print the prompt the step is started with: its "
     & "role, its" & LF
     & "                  assignment (a skill's SKILL.md in full), what the "
     & "run was" & LF
     & "                  started with and how it is to report. After the "
     & "first step" & LF
     & "                  what the step before reported is marked as a slot. "
     & "With" & LF
     & "                  --format json: format "
     & "synapse-pipeline-prompt/v1" & LF
     & "  --input <file>  with --step, the JSON the run is started with, "
     & "or - for" & LF
     & "                  standard input" & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_PIPELINE_PATH     directories of .synapse files besides "
     & "the default" & LF
     & "  SYNAPSE_PIPELINE_HARNESS  the harness of a step that names none"
     & LF
     & "  SYNAPSE_PIPELINE_TIMEOUT, SYNAPSE_PIPELINE_MAX_STEPS, "
     & "SYNAPSE_PIPELINE_RUNNER" & LF
     & "                            the limits the description reports" & LF;

   Next_Help : constant String :=
     "usage: synapse-pipeline next <pipeline> [--input <file>|-] | --state "
     & "<file>|- --result <file>|-" & LF & LF
     & "One step of a run at a time, for a caller that runs the sessions "
     & "itself and" & LF
     & "keeps the state between them. Nothing is run and no harness is "
     & "needed." & LF & LF
     & "  next <pipeline> [--input <file>|-]" & LF
     & "      prints the state a run starts in: the first step to run, with "
     & "the input" & LF
     & "      (JSON; null without one) that step is given" & LF
     & "  next <pipeline> --state <file>|- --result <file>|-" & LF
     & "      takes the state last printed and the result of the step it "
     & "names, a JSON" & LF
     & "      object {""outcome"", ""summary"", ""data""}, and prints the "
     & "state that follows" & LF & LF
     & "The edges, guards and Max_Iterations are applied, and the step "
     & "ceiling is held to," & LF
     & "exactly as 'run' does. A state is the JSON document a running "
     & "pipeline answers" & LF
     & "'state' with; a run is over when its status is completed or failed. "
     & "A failed" & LF
     & "run is data in the state printed and the exit code is 0. A state for "
     & "another" & LF
     & "pipeline, one that is already over, or a result that is not valid "
     & "prints nothing" & LF
     & "and exits 1." & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_PIPELINE_PATH      directories of .synapse files besides "
     & "the default" & LF
     & "  SYNAPSE_PIPELINE_HARNESS   the harness of a step that names none"
     & LF
     & "  SYNAPSE_PIPELINE_MAX_STEPS the most steps a run may take (default "
     & "50)" & LF;

   Run_Help : constant String :=
     "usage: synapse-pipeline run <pipeline> [--input <file>|-] "
     & "[--id <execution-id>]" & LF & LF
     & "Runs the pipeline from its first step, one agent session per step, "
     & "and prints" & LF
     & "the last step's result as JSON on standard output. One line per step "
     & "goes to" & LF
     & "standard error as it finishes. The exit code is 0 when the run "
     & "completes and" & LF
     & "1 when a step fails or the pipeline cannot be run." & LF & LF
     & "  --input <file>   JSON handed to the first step; '-' reads it from "
     & "standard" & LF
     & "                   input" & LF
     & "  --id <id>        the id of the execution, 1 to 64 letters, digits, "
     & "'_' and" & LF
     & "                   '-', instead of one drawn; it needs a work "
     & "directory, and" & LF
     & "                   an id that is taken is an error" & LF & LF
     & "While it runs, the run can be inspected with 'list' and 'info' when "
     & "a work" & LF
     & "directory is set." & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_PIPELINE_PATH      directories of .synapse files besides "
     & "the default" & LF
     & "  SYNAPSE_PIPELINE_HARNESS   the harness of a step that names none"
     & LF
     & "  SYNAPSE_PIPELINE_TIMEOUT   the time limit of a session whose step "
     & "has none," & LF
     & "                             such as 90s or 30m (default 30m)" & LF
     & "  SYNAPSE_PIPELINE_MAX_STEPS the most steps a run may take (default "
     & "50)" & LF
     & "  SYNAPSE_PIPELINE_RUNNER    process (default), or scripted to "
     & "answer from a file" & LF
     & "  SYNAPSE_PIPELINE_SCRIPT    the file a scripted run answers from"
     & LF
     & "  SYNAPSE_WORK_DIR           where Synapse keeps its working files; "
     & "runs are" & LF
     & "                             recorded in pipelines/ under it (default "
     & LF
     & "                             ~/.cache/synapse/work, also given to "
     & "every" & LF
     & "                             session)" & LF
     & "  SYNAPSE_VAULT_DIR, SYNAPSE_CONTENT_ROOT" & LF
     & "                             given to every session" & LF;

   Definitions_Help : constant String :=
     "usage: synapse-pipeline definitions [--format json|text]" & LF & LF
     & "Lists every definition the search directories hold, in alphabetical "
     & "order of name:" & LF
     & "its kind (pipeline, system or agent), name and file. A file that "
     & "does not load" & LF
     & "is not a definition; it is a problem, with its file, line, column "
     & "and message." & LF
     & "Nothing is validated beyond loading, and the exit code is 0 "
     & "whatever is found." & LF & LF
     & "  --format text   for a person (the default)" & LF
     & "  --format json   format synapse-pipeline-definitions/v1: "
     & "`definitions`, each with" & LF
     & "                  kind, name and file, and `problems`, each with "
     & "file, line, column" & LF
     & "                  and message" & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_PIPELINE_PATH     directories of .synapse files besides "
     & "the default" & LF;

   List_Help : constant String :=
     "usage: synapse-pipeline list [--all]" & LF & LF
     & "Lists the runs in progress that were started with the same work "
     & "directory, one" & LF
     & "line each: its execution id, pipeline, status and current step. A "
     & "run that has" & LF
     & "ended, or that died without cleaning up, is not listed. Nothing is "
     & "printed when" & LF
     & "there is none." & LF & LF
     & "  --all   also list the executions that are over and the ones whose "
     & "record is" & LF
     & "          kept, with the status they ended in: completed, failed, "
     & "or" & LF
     & "          interrupted when the record says running and nothing "
     & "answers" & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_WORK_DIR  the work directory runs are recorded under "
     & "(default" & LF
     & "                    ~/.cache/synapse/work)" & LF;

   Info_Help : constant String :=
     "usage: synapse-pipeline info <execution-id> [--format json|text] "
     & "[--query <rule>] | --events" & LF & LF
     & "Asks a run in progress about itself, or reads the record of one that "
     & "is over." & LF
     & "Without --query it prints the "
     & "run in brief:" & LF
     & "execution id, pipeline, status, current step, steps run and the "
     & "failure if there" & LF
     & "is one. With --query it prints the answer to a JsonLogic rule that "
     & "the run" & LF
     & "evaluates over its brief, its state under 'state' and its events "
     & "under 'events'." & LF
     & "Nothing can be started, stopped or changed this way." & LF & LF
     & "  --format text   for a person (the default); a string answer is "
     & "printed bare" & LF
     & "  --format json   the answer as JSON" & LF
     & "  --query <rule>  a JsonLogic rule, such as '{""var"": "
     & """current_step""}'; needs a run that is listening" & LF
     & "  --events        the events recorded for the execution, one JSON "
     & "object a line," & LF
     & "                  from its record; for a run in progress or one that "
     & "is over" & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_WORK_DIR  the work directory the run was recorded under "
     & "(default" & LF
     & "                    ~/.cache/synapse/work)" & LF;

   Cleanup_Help : constant String :=
     "usage: synapse-pipeline cleanup [--older-than <duration>] [--dry-run] "
     & "[--all]" & LF & LF
     & "Removes the records of executions that are over: each one's "
     & "directory, with its" & LF
     & "summary, events and transcripts. An execution that is running, "
     & "because its socket" & LF
     & "answers, is never removed. One that does not answer is removed once "
     & "its last" & LF
     & "write is older than the age given, 30 days when none is." & LF & LF
     & "  --older-than <duration>  the age to keep, a number and d, h, m or "
     & "s, such as 90d" & LF
     & "  --dry-run                say what would be removed and remove "
     & "nothing" & LF
     & "  --all                    also remove the executions that completed "
     & "or failed," & LF
     & "                           whatever their age; one that was "
     & "interrupted is still" & LF
     & "                           kept until it is old enough" & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_WORK_DIR  the work directory the runs were recorded under "
     & "(default" & LF
     & "                    ~/.cache/synapse/work)" & LF;

   Configure_Help : constant String :=
     "usage: synapse-pipeline configure <claude|codex|opencode>" & LF & LF
     & "Installs the skills of this program for a harness: each skill is "
     & "copied, with" & LF
     & "everything beside its SKILL.md, into the harness's skills folder in "
     & "your home" & LF
     & "directory (~/.claude/skills, ~/.codex/skills or "
     & "~/.config/opencode/skill)," & LF
     & "replacing the copy that is there. A skill that an earlier run "
     & "installed and this" & LF
     & "one does not ship is removed; anything else in the folder is left "
     & "as it is." & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_CONTENT_ROOT  the folder that holds skills/" & LF;

   --  The first line of a help text, which is the subcommand's synopsis.
   function Synopsis (Help : String) return String;

end Synapse.Pipeline.Commands.Usage;
