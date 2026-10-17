with Ada.IO_Exceptions;
with Ada.Strings.UTF_Encoding.Conversions;

with Interfaces.C;

package body Synapse.Adapters.Replace_File is

   use type Interfaces.C.int;

   --  MOVEFILE_REPLACE_EXISTING (1) and MOVEFILE_WRITE_THROUGH (8).
   Replace_And_Flush : constant Interfaces.C.unsigned_long := 16#9#;

   function MoveFileExW
     (Existing : Interfaces.C.wchar_array;
      Replaced : Interfaces.C.wchar_array;
      Flags    : Interfaces.C.unsigned_long) return Interfaces.C.int
   with Import, Convention => Stdcall, External_Name => "MoveFileExW";

   function Wide (Path : String) return Interfaces.C.wchar_array
   is (Interfaces.C.To_C
         (Ada.Strings.UTF_Encoding.Conversions.Convert
            (Ada.Strings.UTF_Encoding.UTF_8_String (Path))));

   procedure Replace (Source, Target : String) is
   begin
      if MoveFileExW
           (Wide (Source), Wide (Target), Replace_And_Flush) = 0
      then
         raise Ada.IO_Exceptions.Use_Error
           with "cannot replace " & Target;
      end if;
   end Replace;

end Synapse.Adapters.Replace_File;
