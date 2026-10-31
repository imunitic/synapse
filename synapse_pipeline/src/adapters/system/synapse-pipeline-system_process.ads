with Synapse.Pipeline.Session_Process;

--  Runs programs through the operating system. The body is chosen per
--  platform.

package Synapse.Pipeline.System_Process is

   type System_Process is limited new Session_Process.Process with null record;

   overriding
   function Run
     (P       : in out System_Process;
      Request : Session_Process.Process_Request)
      return Session_Process.Process_Outcome;

end Synapse.Pipeline.System_Process;
