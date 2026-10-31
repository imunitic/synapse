with Ada.Strings.Unbounded;

package body Synapse.Pipeline.Fake_Process is

   use Ada.Strings.Unbounded;

   overriding
   function Run
     (P       : in out Fake_Process;
      Request : Session_Process.Process_Request)
      return Session_Process.Process_Outcome
   is
      Taken : constant Natural := Natural (P.Requests.Length);
   begin
      P.Requests.Append (Request);
      if Taken < Natural (P.Outcomes.Length) then
         return P.Outcomes (Taken + 1);
      end if;
      return
        (Started => False,
         Problem => To_Unbounded_String ("the fake has nothing to run"),
         others  => <>);
   end Run;

   function Exited
     (Output : String; Code : Integer := 0; Errors : String := "")
      return Session_Process.Process_Outcome is
     (Started   => True,
      Exit_Code => Code,
      Output    => To_Unbounded_String (Output),
      Errors    => To_Unbounded_String (Errors),
      others    => <>);

end Synapse.Pipeline.Fake_Process;
