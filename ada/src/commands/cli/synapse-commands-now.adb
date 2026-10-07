with Ada.Strings.Unbounded;

with Synapse.Commands.Cli_Args;
with Synapse.Core.Timestamps;

package body Synapse.Commands.Now is

   LF : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse now [--built-at]" & LF & LF &
     "  (default)    RFC3339 with a numeric offset -- `created`/`updated`'s " &
     "shape" & LF &
     "  --built-at   `YYYY-MM-DD HH:MM`, no seconds or offset -- " &
     "`built_at`'s shape" & LF;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Built_At : Boolean := False;
   begin
      for Arg_Item of Args loop
         declare
            Arg : constant String :=
              Ada.Strings.Unbounded.To_String (Arg_Item);
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg = "--built-at" then
               Built_At := True;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
      end loop;
      declare
         Stamp : constant String := Env.Clock.Timestamp;
      begin
         Say
           (Env,
            (if Built_At then Core.Timestamps.Built_At (Stamp) else Stamp));
      end;
      return 0;
   end Run;

end Synapse.Commands.Now;
