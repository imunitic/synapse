--  `synapse-pipeline list`: the runs there are, each asked for its brief.
--
--  The endpoints of the work directory are found and each is asked; one that
--  does not answer, a file left behind by a run that did not get to clean up,
--  is not a run and is left out. A line is an execution, its pipeline, its
--  status and the step it is at. With no run there is nothing to print.

package Synapse.Pipeline.Commands.List is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.List;
