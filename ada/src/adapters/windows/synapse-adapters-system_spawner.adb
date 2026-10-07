with Ada.Text_IO;

with GNAT.OS_Lib;

package body Synapse.Adapters.System_Spawner is

   use Ada.Strings.Unbounded;

   overriding procedure Spawn_Pusher
     (S : in out System_Spawner; Vault : String)
   is
      Args : GNAT.OS_Lib.Argument_List :=
        [1 => new String'("vault-git-pusher"), 2 => new String'(Vault)];
      Id   : GNAT.OS_Lib.Process_Id;
   begin
      Id :=
        GNAT.OS_Lib.Non_Blocking_Spawn
          (To_String (S.Program), Args, "NUL", Err_To_Out => True);
      for Item of Args loop
         GNAT.OS_Lib.Free (Item);
      end loop;
      if Id = GNAT.OS_Lib.Invalid_Pid then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "synapse: could not spawn the push helper");
      end if;
   end Spawn_Pusher;

end Synapse.Adapters.System_Spawner;
