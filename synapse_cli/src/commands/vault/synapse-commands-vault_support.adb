with Synapse.Adapters.Conf_Files;
with Synapse.Commands.Cli_Args;

package body Synapse.Commands.Vault_Support is

   use Ada.Strings.Unbounded;

   procedure Find_Vault
     (Env   :     Environment; Prog : String; Vault : out Unbounded_String;
      Found : out Boolean)
   is
      Dir : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Vault_Dir (Env.Vars.all);
   begin
      Vault := Null_Unbounded_String;
      Found := Dir.Found;
      if Dir.Found then
         Vault := Dir.Value;
      else
         Complain (Env, Prog & ": no vault" & ASCII.LF);
      end if;
   end Find_Vault;

   procedure Open
     (Env     :        Environment; Prog : String; Vault : String;
      Stack   : in out Store_Resolve.Stack; Ok : out Boolean;
      Spawner : access Synapse.Adapters.Git_Store.Pusher_Spawner'Class := null)
   is
   begin
      Store_Resolve.Resolve
        (S    => Stack, Vars => Env.Vars, Vault => Vault, Namespace => "",
         Prog => Prog, Spawner => Spawner, Valid => Ok);
   end Open;

   function Help_Or_Usage
     (Env : Environment; Arg, Usage_Text : String) return Exit_Code
   is
   begin
      if Cli_Args.Is_Help (Arg) then
         Complain (Env, Usage_Text);
         return 0;
      end if;
      return Usage_Error (Env, Usage_Text);
   end Help_Or_Usage;

   procedure One_Path
     (Env  :     Environment; Args : Lists.Vector; Usage_Text : String;
      Path : out Unbounded_String; Done : out Boolean; Code : out Exit_Code)
   is
   begin
      Path := Null_Unbounded_String;
      Done := True;
      if Args.Is_Empty then
         Code := Usage_Error (Env, Usage_Text);
      elsif Cli_Args.Is_Help (To_String (Args (1))) then
         Complain (Env, Usage_Text);
         Code := 0;
      elsif Natural (Args.Length) > 1 then
         Code := Usage_Error (Env, Usage_Text);
      else
         Path := Args (1);
         Done := False;
         Code := 0;
      end if;
   end One_Path;

end Synapse.Commands.Vault_Support;
