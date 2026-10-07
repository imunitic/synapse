with Ada.Strings.Unbounded;

with Synapse.Ports.Console;

--  A console that keeps what was written and reads from a given text, for
--  tests of what a command prints and returns.

package Synapse.Adapters.Fake_Console is

   type Fake is limited new Synapse.Ports.Console.Console with private;

   --  What a command will read from standard input.
   procedure Set_Stdin (F : in out Fake; Text : String);

   --  Everything written to standard output so far.
   function Out_Text (F : Fake) return String;

   --  Everything written to standard error so far.
   function Err_Text (F : Fake) return String;

   overriding procedure Write_Out (F : in out Fake; Text : String);

   overriding procedure Write_Err (F : in out Fake; Text : String);

   overriding function Read_Stdin (F : in out Fake) return String;

private

   type Fake is limited new Synapse.Ports.Console.Console with record
      Written : Ada.Strings.Unbounded.Unbounded_String;
      Errors  : Ada.Strings.Unbounded.Unbounded_String;
      Input   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Adapters.Fake_Console;
