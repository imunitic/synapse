with Ada.Strings.Unbounded;

--  Helpers for the hand written argument loops of the subcommands: each parses
--  its own flags, so a fix that belongs in the shape of the loop lives here
--  once.

package Synapse.Commands.Cli_Args is

   --  A flag's own value, the argument after it: found only when there is one
   --  and it does not begin with `--`. Without this check `--repo --help`
   --  would take `--help` as the value of `--repo` and hide the real flag
   --  from ever being seen.
   procedure Take_Value
     (Args  :     Lists.Vector; Index : in out Positive;
      Value : out Ada.Strings.Unbounded.Unbounded_String; Found : out Boolean);

   --  After a usage error, the entries of the question to command map for
   --  Sub on standard error: the commands a session was reaching for, in the
   --  form they take. Nothing for a subcommand the map does not cover.
   procedure Print_Map_For (Env : Environment; Sub : String);

   --  Whether the argument asks for help.
   function Is_Help (Arg : String) return Boolean is
     (Arg = "-h" or else Arg = "--help");

end Synapse.Commands.Cli_Args;
