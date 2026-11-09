with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Contexts;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.States;
with Synapse.Ports.Clock;

--  What happens in a run, kept for whoever looks later. Every change the run
--  makes to the execution context goes through here, which passes it on to
--  the context and to the execution's record in the registry, so the pipeline
--  itself does not know there is a registry.
--
--  The record also keeps the description of the pipeline the run began with
--  and the definition files it was made from, beside the summary, as
--  `description.json` and `definitions/`.
--
--  The record is best effort: a write the registry cannot make is left out,
--  and the context, which answers the socket, is changed all the same.
--
--  The summary, `execution.json`:
--
--    {"format": "synapse-pipeline-execution/v1", "id": "exec-...",
--     "pipeline": "Name", "started": timestamp, "ended": null | timestamp,
--     "status": "running" | "completed" | "failed",
--     "current_step": null | "Name", "state": the run's state}
--
--  and each line of `events.jsonl` is one event as the socket gives it.

package Synapse.Pipeline.Recorders is

   Format : constant String := "synapse-pipeline-execution/v1";

   type Recorder
     (Context : not null access Contexts.Execution_Context;
      Store   : not null access Registry_Store.Store'Class;
      Clock   : not null access Synapse.Ports.Clock.Clock'Class)
   is tagged limited private;

   --  Begins the record of the run Id, whose directory the registry holds
   --  when Registered, and the context.
   procedure Start
     (R           : in out Recorder;
      Id          : String;
      Registered  : Boolean;
      Description : Synapse.Core.JSON.Value;
      Initial     : States.State);

   --  Keeps the definition file Path of the run, as the store lays them out.
   --  Written when the run is recorded and left out when it is not.
   procedure Record_Definition (R : in out Recorder; Path, Content : String);

   --  The run has a new state.
   procedure Publish (R : in out Recorder; Item : States.State);

   --  Something happened in the run.
   procedure Record_Event
     (R      : in out Recorder;
      Kind   : String;
      Step   : String;
      Detail : Synapse.Core.JSON.Value);

   --  The summary of a run in the state Item. Ended is empty while it goes.
   function Summary
     (Id, Started, Ended : String; Item : States.State)
      return Synapse.Core.JSON.Value;

private

   type Recorder
     (Context : not null access Contexts.Execution_Context;
      Store   : not null access Registry_Store.Store'Class;
      Clock   : not null access Synapse.Ports.Clock.Clock'Class)
   is tagged limited record
      Id         : Ada.Strings.Unbounded.Unbounded_String;
      Registered : Boolean := False;
      Started    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Pipeline.Recorders;
