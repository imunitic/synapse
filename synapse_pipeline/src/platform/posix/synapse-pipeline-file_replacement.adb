with GNAT.OS_Lib;

package body Synapse.Pipeline.File_Replacement is

   --  rename replaces the file at Path in one step.
   procedure Replace (Temporary, Path : String; Done : out Boolean) is
   begin
      GNAT.OS_Lib.Rename_File (Temporary, Path, Done);
   end Replace;

end Synapse.Pipeline.File_Replacement;
