with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Contexts;
with Synapse.Pipeline.Inspection;
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
--     "pipeline": "Name", "directory": "/where/the/steps/worked",
--     "started": timestamp, "ended": null | timestamp,
--     "status": "running" | "completed" | "failed",
--     "current_step": null | "Name", "state": the run's state,
--     "interactive": whether a person can answer in the run's terminal,
--     "snapshots": {"start": null | tree, "end": null | tree}}
--
--  with one more member, "attention", while an interactive run goes on (see
--  Inspection). "directory" is there when the run was told where its steps
--  work, which is what the patches of its record are the changes of.
--  "snapshots" are the trees of that folder the run pinned when its first
--  session began and when it ended, null until they are pinned.
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
      Initial     : States.State;
      Directory   : String := "";
      Interactive : Boolean := False);

   --  Keeps the definition file Path of the run, as the store lays them out.
   --  Written when the run is recorded and left out when it is not.
   procedure Record_Definition (R : in out Recorder; Path, Content : String);

   --  Keeps Content, the changes a session made as `git diff` prints them, as
   --  the patch called Name. Written when the run is recorded and left out
   --  when it is not.
   procedure Record_Patch (R : in out Recorder; Name, Content : String);

   --  Keeps Content, the result a step visit reported, as the output called
   --  Name. Written when the run is recorded and left out when it is not.
   procedure Record_Output (R : in out Recorder; Name, Content : String);

   --  The run has a new state.
   procedure Publish (R : in out Recorder; Item : States.State);

   --  The snapshot Which ("start" or "end") of the run is the tree Tree, as
   --  pinned in the folder the run works in. Kept in the summary.
   procedure Record_Snapshot (R : in out Recorder; Which, Tree : String);

   --  Something happened in the run.
   procedure Record_Event
     (R      : in out Recorder;
      Kind   : String;
      Step   : String;
      Detail : Synapse.Core.JSON.Value);

   --  The run is waiting for a person (Waiting, with what the agent said as
   --  Reason) or works (Running). Says so in the context, in the summary and,
   --  when it begins or ends waiting, in an event.
   procedure Attend
     (R      : in out Recorder;
      Step   : String;
      State  : Inspection.Attention_State;
      Reason : String := "");

   --  The summary of a run in the state Item. Ended is empty while it goes.
   function Summary
     (Id, Started, Ended : String;
      Item               : States.State;
      Attention          : Inspection.Attention := (others => <>);
      Directory          : String := "";
      Interactive        : Boolean := False;
      Start_Tree         : String := "";
      End_Tree           : String := "")
      return Synapse.Core.JSON.Value;

private

   type Recorder
     (Context : not null access Contexts.Execution_Context;
      Store   : not null access Registry_Store.Store'Class;
      Clock   : not null access Synapse.Ports.Clock.Clock'Class)
   is tagged limited record
      Id          : Ada.Strings.Unbounded.Unbounded_String;
      Registered  : Boolean := False;
      Started     : Ada.Strings.Unbounded.Unbounded_String;
      Directory   : Ada.Strings.Unbounded.Unbounded_String;
      Interactive : Boolean := False;
      Ended       : Ada.Strings.Unbounded.Unbounded_String;
      Start_Tree  : Ada.Strings.Unbounded.Unbounded_String;
      End_Tree    : Ada.Strings.Unbounded.Unbounded_String;
      Last        : States.State;
   end record;

end Synapse.Pipeline.Recorders;
