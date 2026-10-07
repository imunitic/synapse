with Ada.Strings.Unbounded;

with Synapse.Commands.Cli_Args;
with Synapse.Commands.Context;
with Synapse.Core.Command_Map;

package body Synapse.Commands.Show_Context is

   LF : constant Character := Character'Val (10);

   Prog : constant String := "synapse-context";

   Usage_Text : constant String :=
     "usage: synapse context" & LF & LF &
     "  Prints this checkout's graph directory and the question-to-command " &
     "map" & LF & "  the SessionStart hook injects." & LF;

   function Text (Abs_Dir : String) return String is
     ("Synapse graph for this repo and branch: " & Abs_Dir & "/ (map: " &
      Abs_Dir & "/Index.md)" & LF & Core.Command_Map.Render);

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if not Args.Is_Empty then
         Complain (Env, Usage_Text);
         return
           (if Cli_Args.Is_Help (Ada.Strings.Unbounded.To_String (Args (1)))
            then 0
            else 2);
      end if;
      declare
         Found : constant Context.Maybe_Context := Context.Resolve (Env, Prog);
      begin
         if not Found.Found then
            return 1;
         end if;
         if not Context.Verify_Namespace (Env, Found.Item, Prog) then
            return 1;
         end if;
         Say
           (Env, Text (Ada.Strings.Unbounded.To_String (Found.Item.Abs_Dir)));
         return 0;
      end;
   end Run;

end Synapse.Commands.Show_Context;
