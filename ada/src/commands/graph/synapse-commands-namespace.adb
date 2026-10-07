with Ada.Strings.Unbounded;

with Synapse.Adapters.Git_Identity;
with Synapse.Commands.Cli_Args;
with Synapse.Core.Identity;

package body Synapse.Commands.Namespace is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   Prog : constant String := "synapse-namespace";

   Usage_Text : constant String :=
     "usage: synapse namespace [--repo <dir>] [--branch|--repo-name]" & LF &
     LF &
     "  --repo       the checkout to resolve. Default: the one containing " &
     "$PWD." & LF &
     "  --branch     print only the branch half, sanitised for a directory " &
     "name" & LF & "  --repo-name  print only the repo half" & LF;

   type Wanted is (Key, Branch, Repo_Name);

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Repo  : Unbounded_String := To_Unbounded_String (".");
      Want  : Wanted           := Key;
      Index : Natural          := 1;
   begin
      while Index <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (Index));
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg = "--repo" then
               declare
                  Position : Positive := Index;
                  Found    : Boolean;
               begin
                  Cli_Args.Take_Value (Args, Position, Repo, Found);
                  Index := Position;
                  if not Found then
                     return Usage_Error (Env, Usage_Text);
                  end if;
               end;
            elsif Arg = "--branch" then
               Want := Branch;
            elsif Arg = "--repo-name" then
               Want := Repo_Name;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
         Index := Index + 1;
      end loop;

      declare
         Resolved : Core.Identity.Resolved;
      begin
         Resolved := Adapters.Git_Identity.Resolve (To_String (Repo));
         Say
           (Env,
            (case Want is when Key => To_String (Resolved.Key),
               when Branch => To_String (Resolved.Branch_Key),
               when Repo_Name =>
                 Core.Identity.Repo_Name (To_String (Resolved.Remote))));
         return 0;
      exception
         when Core.Identity.Not_A_Git_Repo =>
            Complain (Env, Prog & ": not inside a git repo" & LF);
            return 1;

         when Core.Identity.Detached_Head =>
            Complain (Env, Core.Identity.Detached_Message & LF);
            return 1;

         when others =>
            Complain (Env, Prog & ": could not resolve the namespace" & LF);
            return 1;
      end;
   end Run;

end Synapse.Commands.Namespace;
