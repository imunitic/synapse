with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Git_Identity;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Docstring_Check;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Identity;

package body Synapse.Commands.Comments_Check is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;
   package Check renames Synapse.Commands.Docstring_Check;

   use type Check.Status;

   Prog : constant String    := "synapse-comments-check";
   LF   : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse comments-check <path>" & LF & LF &
     "  Checks one file's docstrings against the docstring index, refreshing" &
     LF &
     "  it with what a fresh parse finds. Silent to stdout when nothing " &
     "is" & LF & "  new or changed. Requires " &
     "SYNAPSE_DOCSTRING_STALENESS_DETECTION (see" & LF &
     "  synapse.conf) -- a no-op otherwise." & LF;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if Args.Is_Empty then
         return Usage_Error (Env, Usage_Text);
      end if;
      declare
         Path_Arg : constant String := To_String (Args (1));
      begin
         if Cli_Args.Is_Help (Path_Arg) then
            Complain (Env, Usage_Text);
            return 0;
         end if;

         declare
            Resolved : Core.Identity.Resolved;
         begin
            begin
               Resolved := Adapters.Git_Identity.Resolve (".");
            exception
               when others =>
                  Complain (Env, Prog & ": not inside a git repo" & LF);
                  return 1;
            end;
            declare
               Root : constant String := To_String (Resolved.Where.Repo_Root);
            begin
               declare
                  Work : constant Support.Maybe_Path :=
                    Support.Work_Dir (Env, Prog);
               begin
                  if not Work.Found then
                     return 1;
                  end if;
                  declare
                     Absolute : constant String :=
                       Ada.Strings.Fixed.Translate
                         (Ada.Directories.Full_Name (Path_Arg),
                          Ada.Strings.Maps.To_Mapping ("\", "/"));
                     Prefix   : constant String := Root & "/";
                  begin
                     if Absolute'Length <= Prefix'Length
                       or else
                         Absolute
                           (Absolute'First ..
                                Absolute'First + Prefix'Length - 1) /=
                         Prefix
                     then
                        Complain
                          (Env,
                           Prog & ": " & Path_Arg & " is not inside " & Root &
                           LF);
                        return 1;
                     end if;
                     declare
                        Found : constant Check.Result :=
                          Check.Check_File
                            (Env, Root, To_String (Work.Value),
                             Absolute
                               (Absolute'First + Prefix'Length ..
                                    Absolute'Last));
                     begin
                        if Found.Which = Check.Failed then
                           Complain
                             (Env, Prog & ": " & To_String (Found.Why) & LF);
                           return 1;
                        end if;
                        if Length (Found.Report) /= 0 then
                           Say (Env, To_String (Found.Report));
                        end if;
                        return 0;
                     end;
                  end;
               end;
            end;
         end;
      end;
   end Run;

end Synapse.Commands.Comments_Check;
