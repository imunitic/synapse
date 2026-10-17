--  The subcommand table: which name runs which command. One table for every
--  entry point, and one place that reports what is wrong with the name or the
--  absence of one.

package Synapse.Commands.Dispatch is

   type Run_Access is
     access function (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  The command a subcommand name runs, or null for a name that is not one.
   function Find (Name : String) return Run_Access;

   --  How many subcommands there are, and the name of each, so that a test
   --  can compare the table with the usage text and the command map.
   function Count return Natural;

   function Name_Of (Index : Positive) return String with
     Pre => Index <= Count;

   --  Runs a command line: its arguments without the program's name. With no
   --  arguments the usage goes to standard error and the code is 2; `--help`
   --  prints the same and returns 0; a name that is not a subcommand is
   --  named, followed by the usage, with code 2.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Dispatch;
