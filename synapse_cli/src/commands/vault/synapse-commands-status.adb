with Ada.Strings.Unbounded;

with Synapse.Commands.Cli_Args;
with Synapse.Commands.Vault_Support;
with Synapse.Core.Vault_Status;
with Synapse.Ports.Store;

package body Synapse.Commands.Status is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Vault_Support;
   package Port renames Synapse.Ports.Store;

   Prog : constant String    := "synapse-status";
   LF   : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse status [--format text|json]" & LF;

   Help_Text : constant String :=
     Usage_Text & LF
     & "Prints what in the vault needs a human decision: design notes still "
     & "being" & LF
     & "discussed, ready ones with no compiled task, ready ones with open "
     & "questions," & LF
     & "open tasks with unchecked items, and tasks waiting for review. Only "
     & "designs/" & LF
     & "and tasks/ are looked at, and nothing is written. --format json "
     & "gives" & LF
     & "synapse-status/v1, every category with its items and their "
     & "paths." & LF;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      As_JSON : Boolean := False;
      I       : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Cli_Args.Is_Help (Arg) then
               Say (Env, Help_Text);
               return 0;
            elsif Arg = "--format" and then I < Natural (Args.Length) then
               I := I + 1;
               declare
                  Format : constant String := To_String (Args (I));
               begin
                  if Format = "json" then
                     As_JSON := True;
                  elsif Format /= "text" then
                     return Usage_Error (Env, Usage_Text);
                  end if;
               end;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
         I := I + 1;
      end loop;

      declare
         Vault : Unbounded_String;
         Found : Boolean;
         Stack : Support.Store_Resolve.Stack;
         Ok    : Boolean;
      begin
         Support.Find_Vault (Env, Prog, Vault, Found);
         if not Found then
            return 1;
         end if;
         Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
         if not Ok then
            return 1;
         end if;
         declare
            Report : constant Synapse.Core.Vault_Status.Report :=
              Synapse.Core.Vault_Status.Build
                (Support.Store_Resolve.Store (Stack).all);
         begin
            if As_JSON then
               Say
                 (Env,
                  Synapse.Core.Vault_Status.To_JSON (Report, To_String (Vault))
                  & LF);
            else
               Say (Env, Synapse.Core.Vault_Status.To_Text (Report));
            end if;
            return 0;
         end;
      exception
         when Port.Store_Failure | Port.Unsafe_Node | Port.Node_Not_Found =>
            Complain (Env, Prog & ": the vault could not be read" & LF);
            return 1;
      end;
   end Run;

end Synapse.Commands.Status;
