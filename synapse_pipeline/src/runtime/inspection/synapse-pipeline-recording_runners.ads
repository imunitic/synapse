with Ada.Strings.Unbounded;

with Synapse.Pipeline.Recorders;
with Synapse.Pipeline.Session_Runner;
with Synapse.Pipeline.Sessions;

--  A runner that runs its inner runner and keeps a record of each session.
--  Every request it passes on names the execution it belongs to, so the inner
--  runner can keep the session's transcript there, and every session ends in
--  a `session.finished` event: the step, the attempt, whether it succeeded
--  and where its transcript is. A step with retries has one such event for
--  each try.

package Synapse.Pipeline.Recording_Runners is

   type Recording_Runner
     (Inner    : not null access Session_Runner.Runner'Class;
      Recorder : not null access Recorders.Recorder)
   is limited new Session_Runner.Runner with record
      --  The execution the sessions belong to.
      Id : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   overriding
   function Run_Session
     (R       : in out Recording_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result;

end Synapse.Pipeline.Recording_Runners;
