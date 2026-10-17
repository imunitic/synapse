with Ada.Text_IO;

with GNAT.OS_Lib;

package body Synapse.Adapters.System_Spawner is

   use Ada.Strings.Unbounded;
   use type GNAT.OS_Lib.String_Access;

   --  The shell starts the program in the background and exits at once, so
   --  waiting for the shell is not waiting for the program. An empty second
   --  argument is left out.
   Script : constant String :=
     """$0"" ""$1"" ${2:+""$2""} </dev/null >/dev/null 2>&1 &";

   procedure Spawn_Detached
     (Program, Command, Argument : String; Success : out Boolean)
   is
      Shell : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path ("sh");
      Args  : GNAT.OS_Lib.Argument_List :=
        [1 => new String'("-c"), 2 => new String'(Script),
        3  => new String'(Program), 4 => new String'(Command),
        5  => new String'(Argument)];
   begin
      Success := False;
      if Shell /= null then
         GNAT.OS_Lib.Spawn (Shell.all, Args, Success);
      end if;
      for Item of Args loop
         GNAT.OS_Lib.Free (Item);
      end loop;
      GNAT.OS_Lib.Free (Shell);
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
