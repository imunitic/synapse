with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;

--  Running one program for a session, supervised: given a directory, extra
--  environment and standard input, held to a time limit, and stopped with
--  everything it started when the limit passes. Implementations are
--  System_Process and, for tests, Fake_Process.

package Synapse.Pipeline.Session_Process is

   type Process_Request is record
      --  A name looked up on PATH, or a path.
      Program         : Ada.Strings.Unbounded.Unbounded_String;
      Arguments       : Synapse.Core.Text_Lists.Vector;

      --  Where the program runs; empty runs it where the caller is.
      Directory       : Ada.Strings.Unbounded.Unbounded_String;

      --  `NAME=value` entries added to the variables the caller has.
      Environment     : Synapse.Core.Text_Lists.Vector;

      --  Written to the program's standard input, which is then closed.
      Standard_Input  : Ada.Strings.Unbounded.Unbounded_String;

      Timeout_Seconds : Positive := 30 * 60;
   end record;

   type Process_Outcome is record
      --  False when the program could not be started; Problem says why and
      --  nothing else is meaningful.
      Started   : Boolean := False;

      --  The program was still running at the limit and was stopped.
      Timed_Out : Boolean := False;

      Exit_Code : Integer := 0;
      Output    : Ada.Strings.Unbounded.Unbounded_String;
      Errors    : Ada.Strings.Unbounded.Unbounded_String;
      Problem   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Process is limited interface;

   --  Runs the program to its end or to the limit. Never raises.
   function Run
     (P       : in out Process;
      Request : Process_Request) return Process_Outcome
   is abstract;

end Synapse.Pipeline.Session_Process;
