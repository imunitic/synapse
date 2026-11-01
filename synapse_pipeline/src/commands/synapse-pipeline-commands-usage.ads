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
     & "  show <pipeline> [--format json|text]" & LF
     & "         describe a pipeline: its steps, settings, edges and limits"
     & LF
     & "  run <pipeline> [--input <file>|-]   run a pipeline to its end" & LF
     & "  list   the pipelines running now" & LF
     & "  info <execution-id> [--format json|text] [--query <rule>]" & LF
     & "         what a running pipeline says about itself" & LF & LF
     & "'synapse-pipeline <subcommand> --help' says more." & LF;

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
     "usage: synapse-pipeline show <pipeline> [--format json|text]" & LF & LF
     & "Describes a pipeline that is not running the way a running one "
     & "describes itself:" & LF
     & "its steps with the settings each will run with, the edges between "
     & "them and" & LF
     & "the limits that apply. The pipeline is found and validated as "
     & "'check' does, and" & LF
     & "nothing is printed on standard output when it cannot be run." & LF & LF
     & "  --format text   for a person (the default)" & LF
     & "  --format json   the document a running pipeline answers its "
     & "'pipeline'" & LF
     & "                  command with, format synapse-pipeline-description/v1"
     & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_PIPELINE_PATH     directories of .synapse files besides "
     & "the default" & LF
     & "  SYNAPSE_PIPELINE_HARNESS  the harness of a step that names none"
     & LF
     & "  SYNAPSE_PIPELINE_TIMEOUT, SYNAPSE_PIPELINE_MAX_STEPS, "
     & "SYNAPSE_PIPELINE_RUNNER" & LF
     & "                            the limits the description reports" & LF;

   Run_Help : constant String :=
     "usage: synapse-pipeline run <pipeline> [--input <file>|-]" & LF & LF
     & "Runs the pipeline from its first step, one agent session per step, "
     & "and prints" & LF
     & "the last step's result as JSON on standard output. One line per step "
     & "goes to" & LF
     & "standard error as it finishes. The exit code is 0 when the run "
     & "completes and" & LF
     & "1 when a step fails or the pipeline cannot be run." & LF & LF
     & "  --input <file>   JSON handed to the first step; '-' reads it from "
     & "standard" & LF
     & "                   input" & LF & LF
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
     & "  SYNAPSE_WORK_DIR           where a run can be inspected from "
     & "(also given to" & LF
     & "                             every session)" & LF
     & "  SYNAPSE_VAULT_DIR, SYNAPSE_CONTENT_ROOT" & LF
     & "                             given to every session" & LF;

   List_Help : constant String :=
     "usage: synapse-pipeline list" & LF & LF
     & "Lists the runs in progress that were started with the same work "
     & "directory, one" & LF
     & "line each: its execution id, pipeline, status and current step. A "
     & "run that has" & LF
     & "ended, or that died without cleaning up, is not listed. Nothing is "
     & "printed when" & LF
     & "there is none." & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_WORK_DIR  the work directory runs are started with" & LF;

   Info_Help : constant String :=
     "usage: synapse-pipeline info <execution-id> [--format json|text] "
     & "[--query <rule>]" & LF & LF
     & "Asks a run in progress about itself. Without --query it prints the "
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
     & """current_step""}'" & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_WORK_DIR  the work directory the run was started with" & LF;

   --  The first line of a help text, which is the subcommand's synopsis.
   function Synopsis (Help : String) return String;

end Synapse.Pipeline.Commands.Usage;
