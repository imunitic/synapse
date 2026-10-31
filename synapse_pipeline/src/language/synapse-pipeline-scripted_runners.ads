with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

with Synapse.Core.Results;
with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Scripts;
with Synapse.Pipeline.Session_Runner;
with Synapse.Pipeline.Sessions;

--  A runner that starts nothing: each session is answered from a script. It
--  is what a pipeline is tested and dry-run with, and with it no harness is
--  needed or looked for.
--
--  A script is a JSON file that maps step names to lists of answers, used up
--  in order across a step's attempts and its trips round a loop:
--
--    {"Review": [{"outcome": "Changes_Requested", "summary": "...",
--                 "data": {}},
--                {"outcome": "Approved", "summary": "...", "data": {}}],
--     "Test":   [{"fail": "quota_exhausted", "reset": "09:00"}]}
--
--  An answer is a result, checked as every result is, or a failure: `fail` is
--  `timeout`, `execution_error`, `result_contract_failure` or
--  `quota_exhausted`, with an optional `message` and an optional `reset`. Any
--  answer may have a `delay_seconds`, how long its session takes before it
--  comes back, so that a run can be watched from outside. A step with no
--  answer left fails with an execution error that says so.

package Synapse.Pipeline.Scripted_Runners is

   --  What is wrong with a script, said by where in it.
   package Script_Results is new Synapse.Core.Results
     (Scripts.Script, Ada.Strings.Unbounded.Unbounded_String);

   function Parse (Text : String) return Script_Results.Result
   with Pre => Text'Last < Positive'Last;

   --  The script in the file at Path.
   function Load
     (Files : File_System.File_System'Class; Path : String)
      return Script_Results.Result;

   --  The longest a scripted session may be made to take.
   Longest_Pause : constant := 3600;

   type Scripted_Runner is limited new Session_Runner.Runner with private;

   function Create (Item : Scripts.Script) return Scripted_Runner;

   --  How many answers the step has left.
   function Remaining (R : Scripted_Runner; Step : String) return Natural;

   overriding
   function Run_Session
     (R : in out Scripted_Runner; Request : Sessions.Session_Request)
      return Sessions.Session_Result;

private

   package Position_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Natural);

   type Scripted_Runner is limited new Session_Runner.Runner with record
      Script : Scripts.Script;

      --  How many answers each step has been given.
      Given  : Position_Maps.Map;
   end record;

end Synapse.Pipeline.Scripted_Runners;
