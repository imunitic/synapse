with Ada.Text_IO;

with GNAT.OS_Lib;

package body Synapse.Adapters.System_Spawner is

   use Ada.Strings.Unbounded;
   use type GNAT.OS_Lib.String_Access;

   --  The shell starts the program in the background and exits at once, so
   --  waiting for the shell is not waiting for the program.
   Script : constant String :=
     """$0"" vault-git-pusher ""$1"" </dev/null >/dev/null 2>&1 &";

   overriding procedure Spawn_Pusher
     (S : in out System_Spawner; Vault : String)
   is
      Shell   : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path ("sh");
      Args    : GNAT.OS_Lib.Argument_List :=
        [1 => new String'("-c"), 2 => new String'(Script),
        3  => new String'(To_String (S.Program)), 4 => new String'(Vault)];
      Success : Boolean                   := False;
   begin
      if Shell /= null then
         GNAT.OS_Lib.Spawn (Shell.all, Args, Success);
      end if;
      for Item of Args loop
         GNAT.OS_Lib.Free (Item);
      end loop;
      GNAT.OS_Lib.Free (Shell);
      if not Success then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "synapse: could not spawn the push helper");
      end if;
   end Spawn_Pusher;

end Synapse.Adapters.System_Spawner;
