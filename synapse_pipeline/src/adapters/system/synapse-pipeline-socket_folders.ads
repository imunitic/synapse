with Synapse.Pipeline.Socket_Paths;

--  What placing the inspector's socket needs of the operating system: the
--  user's id, a folder's real path, and a folder only the user can use. On
--  Windows, where a run listens on a named pipe, these do nothing.

package Synapse.Pipeline.Socket_Folders is

   --  The id of the user running the program; 0 where there is none.
   function User_Id return Socket_Paths.User_Id;

   --  Path with symbolic links resolved and each name spelled as it is on
   --  disk, as realpath(3) gives it; Path itself when it cannot be resolved,
   --  such as when it does not exist.
   function Real_Path (Path : String) return String;

   --  Makes the folder at Path if it is missing, and makes sure only this
   --  user can use it: it must be a directory, not a symbolic link, and
   --  owned by this user, and is left with mode 0700. Says why the folder
   --  cannot be used, or nothing when it can.
   function Make_Private (Path : String) return String;

end Synapse.Pipeline.Socket_Folders;
