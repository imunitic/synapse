with Ada.IO_Exceptions;

with Interfaces.C;

package body Synapse.Adapters.Replace_File is

   use type Interfaces.C.int;

   function C_Rename
     (Old_Name, New_Name : Interfaces.C.char_array) return Interfaces.C.int
   with Import, Convention => C, External_Name => "rename";

   --  rename(2) replaces its target atomically. Ada.Directories.Rename
   --  refuses to replace an existing file.
   procedure Replace (Source, Target : String) is
   begin
      if C_Rename (Interfaces.C.To_C (Source), Interfaces.C.To_C (Target)) /= 0
      then
         raise Ada.IO_Exceptions.Use_Error with "cannot replace " & Target;
      end if;
   end Replace;

end Synapse.Adapters.Replace_File;
