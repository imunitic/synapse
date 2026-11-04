with Interfaces.C;

package body Synapse.Pipeline.File_Replacement is

   use type Interfaces.C.int;

   Replace_Existing : constant Interfaces.C.unsigned_long := 1;

   function Move_File
     (Existing, Target : Interfaces.C.char_array;
      Flags            : Interfaces.C.unsigned_long) return Interfaces.C.int
   with Import, Convention => Stdcall, External_Name => "MoveFileExA";

   --  Renaming over a file that is there fails on Windows unless it is asked
   --  to replace it.
   procedure Replace (Temporary, Path : String; Done : out Boolean) is
   begin
      Done :=
        Move_File
          (Interfaces.C.To_C (Temporary), Interfaces.C.To_C (Path),
           Replace_Existing) /= 0;
   end Replace;

end Synapse.Pipeline.File_Replacement;
