with Synapse.Core.JSON;
with Synapse.Pipeline.Inspection;
with Synapse.Pipeline.States;

--  The run, held where its own task can change it and another can read it.
--  The task that runs the pipeline starts the context, publishes each new
--  state and records what happens; the task that answers questions takes a
--  snapshot and works from that, so what it reads never changes under it and
--  nothing it does reaches the run.

package Synapse.Pipeline.Contexts is

   protected type Execution_Context is

      --  Begins the context: the run's identity and where it starts.
      procedure Start (Id : String; Initial : States.State);

      procedure Publish (Item : States.State);

      --  Records an event after the ones before it. Past Max_Events the
      --  oldest is forgotten.
      procedure Record_Event
        (Kind, Step : String; Detail : Synapse.Core.JSON.Value);

      function Current return Inspection.Snapshot;

   private
      Data : Inspection.Snapshot;
      Next : Positive := 1;
   end Execution_Context;

end Synapse.Pipeline.Contexts;
