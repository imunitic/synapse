with Ada.Containers.Vectors;

with Synapse.Pipeline.Session_Process;

--  A process that runs nothing: it records the requests it is given and
--  answers each with the next outcome it was told to give.

package Synapse.Pipeline.Fake_Process is

   package Request_Vectors is new Ada.Containers.Vectors
     (Positive, Session_Process.Process_Request, Session_Process."=");

   package Outcome_Vectors is new Ada.Containers.Vectors
     (Positive, Session_Process.Process_Outcome, Session_Process."=");

   type Fake_Process is limited new Session_Process.Process with record
      Requests : Request_Vectors.Vector;

      --  Answered in order; a run past the last one finds a program that
      --  could not be started.
      Outcomes : Outcome_Vectors.Vector;
   end record;

   overriding
   function Run
     (P       : in out Fake_Process;
      Request : Session_Process.Process_Request)
      return Session_Process.Process_Outcome;

   --  An outcome of a program that ran and exited with Code.
   function Exited
     (Output : String; Code : Integer := 0; Errors : String := "")
      return Session_Process.Process_Outcome;

end Synapse.Pipeline.Fake_Process;
