with Ada.Strings.Unbounded;

with Synapse.Adapters.Git_Identity;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Docstring_Check;
with Synapse.Commands.Enumerate;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Identity;

package body Synapse.Commands.Comments_Sweep is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;
   package Check renames Synapse.Commands.Docstring_Check;

   use type Check.Status;

   Prog : constant String    := "synapse-comments-sweep";
   LF   : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse comments-sweep [--reenumerate]" & LF & LF &
     "  Checks every tracked file's docstrings against the docstring index," &
     LF & "  refreshing it with what a fresh parse finds -- the whole-repo " &
     "sweep" & LF & "  counterpart to `comments-check <path>`. Requires" & LF &
     "  SYNAPSE_DOCSTRING_STALENESS_DETECTION (see synapse.conf) -- a no-op" &
     LF & "  otherwise." & LF;

   Largest_Listing : constant := 256 * 1_024 * 1_024;

   function Sweep
     (Env : Environment; Identity_Path : String; Reenumerate : Boolean)
      return Exit_Code
   is
      Resolved : Core.Identity.Resolved;
   begin
      begin
         Resolved := Adapters.Git_Identity.Resolve (Identity_Path);
      exception
         when others =>
            Complain (Env, Prog & ": not inside a git repo" & LF);
            return 1;
      end;
      declare
         Root : constant String := To_String (Resolved.Where.Repo_Root);
         Work : constant Support.Maybe_Path :=
           Support.Work_Dir (Env, Prog, Identity_Path);
      begin
         if not Work.Found then
            Complain (Env, Prog & ": could not resolve a work directory" & LF);
            return 1;
         end if;
         if not Enumerate.Ensure
             (Env, Root, To_String (Work.Value), Reenumerate)
         then
            return 1;
         end if;
         declare
            Listing : Unbounded_String;
            Read    : Boolean;
            Files   : Natural := 0;
            Changed : Natural := 0;
            Evicted : Natural := 0;
         begin
            Support.Read_File
              (To_String (Work.Value) & "/all.txt",
               Support.Max_Listing_Bytes (Env, Largest_Listing), Listing,
               Read);
            if not Read then
               Complain
                 (Env,
                  Prog & ": cannot read " & To_String (Work.Value) &
                  "/all.txt" & LF);
               return 1;
            end if;
            declare
               Whole : constant String := To_String (Listing);
               Start : Positive        := Whole'First;
            begin
               for I in Whole'First .. Whole'Last + 1 loop
                  if I > Whole'Last or else Whole (I) = LF then
                     if I > Start then
                        declare
                           Rel   : constant String := Whole (Start .. I - 1);
                           Found : constant Check.Result :=
                             Check.Check_File
                               (Env, Root, To_String (Work.Value), Rel);
                        begin
                           if Found.Which = Check.Failed then
                              Complain
                                (Env,
                                 Prog & ": " & To_String (Found.Why) & LF);
                              return 1;
                           end if;
                           Files   := Files + 1;
                           Changed := Changed + Found.Updated;
                           Evicted := Evicted + Found.Evicted;
                           if Length (Found.Report) /= 0 then
                              Say
                                (Env,
                                 "-- " & Rel & " --" & LF &
                                 To_String (Found.Report) & LF & LF);
                           end if;
                        end;
                     end if;
                     Start := I + 1;
                  end if;
               end loop;
            end;
            Say
              (Env,
               "comments-sweep: " & Core.Decimal_Image.Image (Files) &
               " files checked, " & Core.Decimal_Image.Image (Changed) &
               " changed, " & Core.Decimal_Image.Image (Evicted) & " evicted" &
               LF);
            return 0;
         end;
      end;
   end Sweep;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Reenumerate : Boolean := False;
   begin
      for Arg_Item of Args loop
         declare
            Arg : constant String := To_String (Arg_Item);
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg = "--reenumerate" then
               Reenumerate := True;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
      end loop;
      return Sweep (Env, ".", Reenumerate);
   end Run;

end Synapse.Commands.Comments_Sweep;
