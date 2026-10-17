with Synapse.Ports.Console;

--  The process's own standard streams, written and read as raw bytes.

package Synapse.Adapters.System_Console is

   type System_Console is
   limited new Synapse.Ports.Console.Console with null record;

   overriding procedure Write_Out (C : in out System_Console; Text : String);

   overriding procedure Write_Err (C : in out System_Console; Text : String);

   overriding function Read_Stdin (C : in out System_Console) return String;

end Synapse.Adapters.System_Console;
