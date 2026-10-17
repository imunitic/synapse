--  What a command reads and writes: standard output, standard error and
--  standard input. Passed in, so a command is tested by what it writes and not
--  by capturing the process's own streams. Implementations live under
--  Synapse.Adapters.
--
--  Text goes through byte for byte: no line ending is added or translated, and
--  none is dropped, since callers substitute the output into paths and values.

package Synapse.Ports.Console is

   type Console is limited interface;

   procedure Write_Out (C : in out Console; Text : String) is abstract;

   --  Diagnostics and usage text. Written as it is given and not buffered
   --  behind standard output.
   procedure Write_Err (C : in out Console; Text : String) is abstract;

   --  All of standard input, to its end. Empty when there is none.
   function Read_Stdin (C : in out Console) return String is abstract;

end Synapse.Ports.Console;
