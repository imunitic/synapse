--  Keeping what the program writes to the user alone. Where the operating
--  system has no such modes, these do nothing.

package Synapse.Pipeline.Private_Access is

   --  Only the user may enter and list the directory at Path.
   procedure Directory (Path : String);

   --  Only the user may read and write the file at Path.
   procedure File (Path : String);

end Synapse.Pipeline.Private_Access;
