with Ada.Text_IO;

with GNAT.OS_Lib;

package body Synapse.Adapters.System_Spawner is

   use Ada.Strings.Unbounded;
   use type GNAT.OS_Lib.Process_Id;

   procedure Spawn_Detached
     (Program, Command, Argument : String; Success : out Boolean)
   is
      Args : GNAT.OS_Lib.Argument_List :=
        (if Argument = "" then [1 => new String'(Command)]
         else [1 => new String'(Command), 2 => new String'(Argument)]);
      Id   : GNAT.OS_Lib.Process_Id;
   begin
      Id :=
        GNAT.OS_Lib.Non_Blocking_Spawn
          (Program, Args, "NUL", Err_To_Out => True);
      Success := Id /= GNAT.OS_Lib.Invalid_Pid;
      for Item of Args loop
         GNAT.OS_Lib.Free (Item);
      end loop;
   end Spawn_Detached;

   overriding procedure Spawn_Pusher
     (S : in out System_Spawner; Vault : String)
   is
      Success : Boolean;
   begin
      Spawn_Detached
        (To_String (S.Program), "vault-git-pusher", Vault, Success);
      if not Success then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "synapse: could not spawn the push helper");
      end if;
   end Spawn_Pusher;

end Synapse.Adapters.System_Spawner;
