with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Win32;

--  What running a program on Windows takes besides starting it: finding the
--  file a name stands for, writing the command line that runs it, and the
--  environment it is given. Shared by the adapters that run programs.

package Synapse.Pipeline.Windows_Programs is

   --  The file a program name stands for: where it says, or else in the first
   --  directory on PATH that has it, with the extensions of PATHEXT tried in
   --  turn. Empty when there is none.
   function Locate (Program : String) return String;

   --  The command line that runs the file at Path with Arguments, each quoted
   --  the way the C library of Windows reads it back. A script is run by the
   --  command interpreter.
   function Command_Line
     (Path : String; Arguments : Synapse.Core.Text_Lists.Vector) return String;

   --  The variables of this program with Extra (`NAME=value`) added, replacing
   --  any of the same name, as the block CreateProcess takes.
   function Environment_Block
     (Extra : Synapse.Core.Text_Lists.Vector) return Wide_String;

   --  A number as text, without the blank `Image` puts before it.
   function Image (Item : Win32.DWORD) return String;

   --  Closes a handle that is open, and makes it null.
   procedure Close (Item : in out Win32.HANDLE);

end Synapse.Pipeline.Windows_Programs;
