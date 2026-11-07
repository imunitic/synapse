with Ada.Strings.Unbounded;

with Synapse.Adapters.Work_Dirs;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;

package body Synapse.Commands.Work_Dir is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;

   Prog : constant String    := "synapse-work-dir";
   LF   : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse work-dir [--root | --namespace <repo>@<branch>]" & LF;

   Help_Text : constant String :=
     Usage_Text & LF
     & "Prints where Synapse keeps its working files: the folder of this "
     & "repository's" & LF
     & "namespace, or with --namespace that of another, or with --root the "
     & "directory" & LF
     & "they are folders of. The root is SYNAPSE_WORK_DIR, else "
     & ".cache/synapse/work in" & LF
     & "the home directory. Nothing is created." & LF;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Count : constant Natural := Natural (Args.Length);
   begin
      if Count = 1 and then Cli_Args.Is_Help (To_String (Args (1))) then
         Say (Env, Help_Text);
         return 0;
      elsif Count = 1 and then To_String (Args (1)) = "--root" then
         declare
            Root : constant String :=
              Synapse.Adapters.Work_Dirs.Root (Env.Vars.all);
         begin
            if Root = "" then
               Complain
                 (Env, Prog & ": no HOME, so no default work dir" & LF);
               return 1;
            end if;
            Say (Env, Root & LF);
            return 0;
         end;
      elsif Count = 2 and then To_String (Args (1)) = "--namespace" then
         declare
            Where : constant Support.Maybe_Path :=
              Support.Work_Dir_For_Namespace
                (Env, To_String (Args (2)), Prog);
         begin
            if not Where.Found then
               return 1;
            end if;
            Say (Env, To_String (Where.Value) & LF);
            return 0;
         end;
      elsif Count = 0 then
         declare
            Where : constant Support.Maybe_Path :=
              Support.Work_Dir (Env, Prog);
         begin
            if not Where.Found then
               return 1;
            end if;
            Say (Env, To_String (Where.Value) & LF);
            return 0;
         end;
      end if;
      return Usage_Error (Env, Usage_Text);
   end Run;

end Synapse.Commands.Work_Dir;
