with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Session_Runner;
with Synapse.Pipeline.States;

--  The state machine: where a pipeline goes next. Execute_Step is the one
--  operation that understands a transition. Everything else, running to the
--  end or doing one step at a time for a caller that keeps the state, only
--  decides whether to ask for another.
--
--  One call takes a run that is still going and runs its current step:
--    * it fails the run, before starting, when the run has already taken as
--      many steps as the configuration allows;
--    * the step's session is asked of the runner, and is asked again, up to
--      the step's `Retries` more times, after an execution error or a result
--      that failed its checks; a quota that is used up is not asked again,
--      since asking at once fails the same way;
--    * the result's guards are tried in the order of the edges leaving the
--      step, and the first that holds sends the run along its edge; when none
--      does, the run goes on to the next step declared, and past the last one
--      it is completed.
--
--  A failure of any kind returns the run as it was, marked failed and saying
--  why, with nothing taken from the session that failed: the step it
--  happened in is where a caller starts again. Only a step that gave a result
--  and was routed moves the run on, and then every part of the new state
--  changes together.

package Synapse.Pipeline.Engine is

   use type States.Run_Status;

   function Execute_Step
     (Pipeline : Resolved.Pipeline;
      Run      : States.State;
      Settings : Configs.Config;
      Runner   : in out Session_Runner.Runner'Class) return States.State
   with Pre => Run.Status = States.Running;

end Synapse.Pipeline.Engine;
