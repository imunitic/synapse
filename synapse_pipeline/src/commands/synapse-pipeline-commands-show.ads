--  `synapse-pipeline show <pipeline> [--format json|text]`: a pipeline that
--  is not running, described as a running one describes itself.
--
--  The pipeline is found as `check` finds it, and a pipeline that does not
--  resolve prints nothing on standard output and exits with 1 after the same
--  errors. With --format json the document is the one of Descriptions, the
--  one the `pipeline` command of a run answers with; with text, which is the
--  default, the same information is laid out for a person.

package Synapse.Pipeline.Commands.Show is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Show;
