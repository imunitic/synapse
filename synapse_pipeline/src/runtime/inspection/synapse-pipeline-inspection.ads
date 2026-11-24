with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.States;

--  What a running pipeline says about itself to whoever asks, and how it
--  answers. A request is one JSON object naming a command, and the answer is
--  one JSON object:
--
--    {"command": "info"}                     the run in brief
--    {"command": "state"}                    the run's whole state
--    {"command": "pipeline"}                 the pipeline the run executes
--                                            (see Descriptions)
--    {"command": "events", "after": 12}      what happened, newest last
--    {"command": "query", "expression": R}   a JsonLogic rule evaluated over
--                                            the run
--    answers: {"ok": true, "result": ...} or {"ok": false, "error": "..."}
--
--  The brief of a run that is interactive has one more member, `attention`:
--  `{"state": "running" | "waiting", "reason": null | text, "since": time}`.
--  A run is waiting when the agent has handed control to a person, with what
--  it said as the reason, and running when it works. A run that is not
--  interactive, or is over, has none.
--
--  Every command reads and none changes anything: there is no command that
--  runs, advances, retries or cancels, and a name that is not one of the five
--  is an error. A query is evaluated over the info members, the state under
--  `state`, the events under `events` and the pipeline's description under
--  `pipeline`, so that `{"var": "current_step"}`,
--  `{"var": "state.previous_output.outcome"}` and
--  `{"var": "pipeline.steps"}` all work.
--
--  A request longer than Max_Request_Bytes is refused unread, and an answer
--  longer than Max_Response_Bytes is replaced by an error saying so.

package Synapse.Pipeline.Inspection is

   package JSON renames Synapse.Core.JSON;

   Max_Request_Bytes  : constant := 4096;
   Max_Response_Bytes : constant := 1024 * 1024;

   --  How many events are kept; the oldest are dropped first.
   Max_Events : constant := 200;

   --  Something that happened in the run, numbered from 1 in the order it
   --  happened.
   type Event is record
      Sequence : Positive := 1;

      --  `run.started`, `step.started`, `session.started`,
      --  `session.waiting`, `session.resumed`, `session.finished`,
      --  `step.finished`, `run.completed` or `run.failed`.
      Kind     : Ada.Strings.Unbounded.Unbounded_String;
      Step     : Ada.Strings.Unbounded.Unbounded_String;
      Detail   : JSON.Value;
   end record;

   package Event_Vectors is new Ada.Containers.Vectors (Positive, Event);

   --  Whether the run is waiting for a person. Absent for a run that is not
   --  interactive.
   type Attention_State is (Absent, Running, Waiting);

   type Attention is record
      State  : Attention_State := Absent;

      --  What the agent said when it handed control over; empty when running.
      Reason : Ada.Strings.Unbounded.Unbounded_String;

      --  When the state began.
      Since  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  The attention as the brief gives it; null when absent.
   function Attention_JSON (Item : Attention) return JSON.Value;

   --  The run as it was at one moment.
   type Snapshot is record
      Execution_Id : Ada.Strings.Unbounded.Unbounded_String;

      --  The pipeline the run executes, as Descriptions describes it. Set
      --  when the run starts and the same for all of it.
      Description  : JSON.Value;
      Run          : States.State;
      Events       : Event_Vectors.Vector;
      Attention    : Inspection.Attention;
   end record;

   function Event_JSON (Item : Event) return JSON.Value;

   --  The run in brief.
   function Info (Seen : Snapshot) return JSON.Value;

   --  The answer to one request, as the text to send back. Never raises.
   function Respond (Seen : Snapshot; Request : String) return String;

end Synapse.Pipeline.Inspection;
