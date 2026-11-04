--  Putting a file in place of another in one step, so that a reader sees the
--  old file or the new one and never part of either.

package Synapse.Pipeline.File_Replacement is

   --  Renames Temporary to Path, replacing the file that is at Path. Done is
   --  False when it could not be done, and Temporary is then still there.
   procedure Replace (Temporary, Path : String; Done : out Boolean);

end Synapse.Pipeline.File_Replacement;
