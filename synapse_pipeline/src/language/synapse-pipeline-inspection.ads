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
--    {"command": "events", "after": 12}      what happened, newest last
--    {"command": "query", "expression": R}   a JsonLogic rule evaluated over
--                                            the run
--    answers: {"ok": true, "result": ...} or {"ok": false, "error": "..."}
--
--  Every command reads and none changes anything: there is no command that
--  runs, advances, retries or cancels, and a name that is not one of the four
--  is an error. A query is evaluated over the info members, the state under
--  `state` and the events under `events`, so that `{"var": "current_step"}`
--  and `{"var": "state.previous_output.outcome"}` both work.
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

      --  `run.started`, `step.started`, `step.finished`, `run.completed` or
      --  `run.failed`.
      Kind     : Ada.Strings.Unbounded.Unbounded_String;
      Step     : Ada.Strings.Unbounded.Unbounded_String;
      Detail   : JSON.Value;
   end record;

   package Event_Vectors is new Ada.Containers.Vectors (Positive, Event);

   --  The run as it was at one moment.
   type Snapshot is record
      Execution_Id : Ada.Strings.Unbounded.Unbounded_String;
      Run          : States.State;
      Events       : Event_Vectors.Vector;
   end record;

   function Event_JSON (Item : Event) return JSON.Value;

   --  The run in brief.
   function Info (Seen : Snapshot) return JSON.Value;

   --  The answer to one request, as the text to send back. Never raises.
   function Respond (Seen : Snapshot; Request : String) return String;

end Synapse.Pipeline.Inspection;
