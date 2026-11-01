with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Search_Paths;
with Synapse.Pipeline.Session_Process;
with Synapse.Pipeline.Session_Runner;
with Synapse.Pipeline.Sessions;

--  Runs a session as a process of the step's harness. The step's role and
--  assignment, with the skill it names read from its `SKILL.md`, become the
--  prompt; the harness is run in the configuration's working directory with
--  the configuration's environment added, held to the session's time limit;
--  and what it answers is checked as every result is.
--
--  Nothing here raises: a harness that is not installed, one that times out,
--  one that reports a quota and one that answers badly each come back as the
--  failure that says so.

package Synapse.Pipeline.Process_Runners is

   type Process_Runner
     (Process : not null access Session_Process.Process'Class;
      Files   : not null access File_System.File_System'Class)
   is limited new Session_Runner.Runner with record
      --  Where a skill is looked for, in order.
      Skill_Roots : Search_Paths.Root_Vectors.Vector;
   end record;

   overriding
   function Run_Session
     (R       : in out Process_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result;

end Synapse.Pipeline.Process_Runners;
