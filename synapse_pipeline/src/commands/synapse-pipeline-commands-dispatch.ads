--  The subcommand table: which name runs which command, and the one place
--  that reports what is wrong with the name or the absence of one.

package Synapse.Pipeline.Commands.Dispatch is

   --  Runs a command line: its arguments without the program's name. With no
   --  arguments the usage goes to standard error and the code is 2; `--help`
   --  prints the same, also to standard error, and returns 0; a name that is
   --  not a subcommand is named, followed by the usage, with code 2.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Dispatch;
