--  Moving a file over another in one step, so a reader sees the old file or
--  the new one and never a mixture. Implemented per operating system.

package Synapse.Adapters.Replace_File is

   --  Makes Target the file Source was, replacing Target if it exists.
   --  Raises Ada.IO_Exceptions.Use_Error when the move fails.
   procedure Replace (Source, Target : String);

end Synapse.Adapters.Replace_File;
