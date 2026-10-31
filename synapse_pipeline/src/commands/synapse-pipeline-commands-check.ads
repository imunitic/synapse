--  `synapse-pipeline check <pipeline>`: whether a pipeline can run, and what
--  it would run with.
--
--  The definitions are loaded from the search directories; a definition that
--  does not load is a warning on standard error, whether or not the pipeline
--  uses it. Then the pipeline is validated, and every problem is reported on
--  standard error with the code 1. A pipeline that can run is printed on
--  standard output, each step with its harness and the file each system and
--  agent it uses came from and the directory each skill was found in, and the
--  code is 0.

package Synapse.Pipeline.Commands.Check is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Check;
