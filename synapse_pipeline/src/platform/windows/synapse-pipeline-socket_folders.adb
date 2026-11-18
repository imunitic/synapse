--  A run on Windows listens on a named pipe, so nothing here is used.

package body Synapse.Pipeline.Socket_Folders is

   function User_Id return Socket_Paths.User_Id is (0);

   function Real_Path (Path : String) return String is (Path);

   function Make_Private (Path : String) return String is
      pragma Unreferenced (Path);
   begin
      return "";
   end Make_Private;

end Synapse.Pipeline.Socket_Folders;
