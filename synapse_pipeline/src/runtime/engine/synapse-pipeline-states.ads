with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Results;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Guards;
with Synapse.Pipeline.Resolved;

--  Where a run of a pipeline has got to. It is all there is to know: a step
--  is run from a state and a snapshot, and a state is the answer. It holds
--  nothing that lives only in a process, so a caller can keep it between one
--  step and the next.
--
--    {"format": "synapse-pipeline-state/v1", "pipeline": "Name",
--     "status": "running" | "completed" | "failed",
--     "current_step": "Name", "initial_input": ..., "previous_output": ...,
--     "fired": [n, ...], "steps_run": n,
--     "failure": null | {"kind", "step", "message", "reset"}}

package Synapse.Pipeline.States is

   Format : constant String := "synapse-pipeline-state/v1";

   type Run_Status is (Running, Completed, Failed);

   type State is record
      Pipeline        : Ada.Strings.Unbounded.Unbounded_String;
      Status          : Run_Status := Running;

      --  The step to run next; empty once the run is over.
      Current_Step    : Ada.Strings.Unbounded.Unbounded_String;

      --  What the run was started with, the same throughout.
      Initial_Input   : Synapse.Core.JSON.Value;

      --  The last step's result, null before any step has run.
      Previous_Output : Synapse.Core.JSON.Value;

      --  How many times each edge has fired, in the order of the pipeline's
      --  edges.
      Fired           : Guards.Count_Vectors.Vector;

      --  How many steps have run, for the ceiling.
      Steps_Run       : Natural := 0;

      --  Why the run failed; meaningful only when Status is Failed.
      Failure         : Failures.Failure;
   end record;

   --  The state a run starts in: at the first step, nothing yet fired.
   function Initial
     (Item : Resolved.Pipeline; Input : Synapse.Core.JSON.Value) return State
   with Pre => not Item.Steps.Is_Empty;

   function Is_Terminal (Item : State) return Boolean is
     (Item.Status /= Running);

   function To_JSON (Item : State) return Synapse.Core.JSON.Value;

   function To_Text (Item : State) return String;

   --  What is wrong with a document, said by where in it.
   package State_Results is new Synapse.Core.Results
     (State, Ada.Strings.Unbounded.Unbounded_String);

   function From_JSON
     (Document : Synapse.Core.JSON.Value) return State_Results.Result;

   function Parse (Text : String) return State_Results.Result
   with Pre => Text'Last < Positive'Last;

end Synapse.Pipeline.States;
