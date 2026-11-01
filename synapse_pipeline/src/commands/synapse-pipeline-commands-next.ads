--  `synapse-pipeline next`: one step of a run at a time, for a caller that
--  runs the sessions itself and keeps the state between them.
--
--    next <pipeline> [--input <file>|-]
--    next <pipeline> --state <file>|- --result <file>|-
--
--  The first form prints the state a run of the pipeline starts in, with the
--  input handed to its first step (null without one). The second takes the
--  state a caller was last given and the result of the step that state names,
--  and prints the state that follows: the edges, guards, `Max_Iterations` and
--  the step ceiling are applied exactly as `run` applies them. A state is the
--  `synapse-pipeline-state/v1` document that a running pipeline answers
--  `state` with.
--
--  A run that failed, a guard that cannot be evaluated or a ceiling that has
--  been reached is data in the state printed, and the code is 0. A state that
--  cannot be used, for another pipeline or already over, or a result that
--  breaks the contract prints nothing on standard output and returns 1 with
--  the reason on standard error.

package Synapse.Pipeline.Commands.Next is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Next;
