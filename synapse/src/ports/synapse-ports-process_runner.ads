with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;

--  Running another program and capturing what it writes. Implementations
--  live under Synapse.Adapters.

package Synapse.Ports.Process_Runner is

   use Ada.Strings.Unbounded;

   --  The program could not be started, or wrote more than Largest_Output
   --  bytes to a stream.
   Process_Failure : exception;

   Largest_Output : constant := 64 * 1024 * 1024;

   type Options is record
      --  The directory to run in; empty runs in the current one.
      Cwd       : Unbounded_String;

      --  Text written to the program's standard input, which is then closed.
      --  Without it standard input is empty.
      Has_Stdin : Boolean := False;
      Stdin     : Unbounded_String;
   end record;

   type Result is record
      --  A program killed by a signal reports 128 plus the signal where the
      --  system says which.
      Exit_Code : Integer := 0;
      Output    : Unbounded_String;
      Errors    : Unbounded_String;
   end record;

   function Succeeded (R : Result) return Boolean
   is (R.Exit_Code = 0);

   type Runner is limited interface;

   --  Runs Program with Args (not the program's own name) and waits for it. A
   --  Program with no directory part is looked up on PATH. Arguments reach
   --  the program as they are: none is interpreted by a shell. A non-zero
   --  exit is a Result, not an exception.
   function Run
     (R       : in out Runner;
      Program : String;
      Args    : Core.Text_Lists.Vector;
      Opts    : Options) return Result
   is abstract;

end Synapse.Ports.Process_Runner;
