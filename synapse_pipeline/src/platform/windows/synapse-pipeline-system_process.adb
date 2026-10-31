with Ada.Strings.Unbounded;

package body Synapse.Pipeline.System_Process is

   overriding
   function Run
     (P       : in out System_Process;
      Request : Session_Process.Process_Request)
      return Session_Process.Process_Outcome
   is
      pragma Unreferenced (P, Request);
   begin
      return
        (Started => False,
         Problem =>
           Ada.Strings.Unbounded.To_Unbounded_String
             ("running a harness is not available on this platform yet"),
         others  => <>);
   end Run;

end Synapse.Pipeline.System_Process;
