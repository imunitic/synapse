with Ada.Strings.Unbounded;

with Synapse.Hooks.Prompt_Context;
with Synapse.Hooks.Session_Start;
with Synapse.Hooks.Staleness;
with Synapse.Hooks.Stop_Nudge;

package body Synapse.Hooks.Dispatch is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse-hook <hook>" & LF & LF &
     "  staleness        PostToolUse: flag owning nodes, check cited evidence" &
     LF &
     "  prompt-context   UserPromptSubmit: the standing one-line pointer" &
     LF &
     "  session-start    SessionStart: inject the vault index and the pointer" &
     LF & "  stop-nudge       Stop: the periodic capture check-in" & LF;

   function Run
     (Env : Environment; Args : Synapse.Commands.Lists.Vector)
      return Synapse.Commands.Exit_Code
   is
   begin
      if Args.Is_Empty then
         Complain (Env, Usage_Text);
         return 2;
      end if;
      declare
         Which : constant String := To_String (Args (1));
      begin
         if Which in "-h" | "--help" then
            Complain (Env, Usage_Text);
            return 0;
         end if;
         begin
            if Which = "staleness" then
               Staleness.Run (Env);
            elsif Which = "prompt-context" then
               Prompt_Context.Run (Env);
            elsif Which = "session-start" then
               Session_Start.Run (Env);
            elsif Which = "stop-nudge" then
               Stop_Nudge.Run (Env);
            elsif Which = "vault-pull" then
               --  Not registered as a hook: `session-start` runs this
               --  detached, so a turn never waits on the network.
               Stop_Nudge.Pull (Env);
            else
               Complain
                 (Env,
                  "synapse-hook: unknown hook '" & Which & "'" & LF &
                  Usage_Text);
               return 2;
            end if;
         exception
            when others =>
               null;
         end;
         return 0;
      end;
   end Run;

end Synapse.Hooks.Dispatch;
