--  `synapse-pipeline run <pipeline> [--input <file>] [--id <id>]`: runs a
--  pipeline from its first step to its end.
--
--  Everything the run depends on is settled before its first session: the
--  configuration from the variables, and the pipeline with the systems and
--  agents it names, loaded, checked and resolved. The run then keeps that and
--  its own state in memory and looks nothing up again, so editing a
--  definition, changing a setting or switching the vault directory reaches no
--  run that has begun. With a work directory the run also keeps its record
--  there.
--
--  The input is the JSON in the file, or on standard input for `-`, and is
--  null when none is given. The execution has the id given with `--id`, or
--  one that is drawn. An id that was asked for needs a work directory, and is
--  refused when it is taken, never replaced by another. A definition that did
--  not load is a warning; a pipeline that cannot run is reported, with every
--  problem, before any session is started.
--
--  When the run completes, its result, the last step's, is written to
--  standard output and the code is 0. Each step as it finishes is one line on
--  standard error. When the run fails, the step, the kind of failure and the
--  reason go to standard error and the code is 1.

package Synapse.Pipeline.Commands.Run is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Run;
