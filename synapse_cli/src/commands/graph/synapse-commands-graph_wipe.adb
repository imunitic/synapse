with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.File_Bytes;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Context;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Emit;

package body Synapse.Commands.Graph_Wipe is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;

   Prog : constant String    := "synapse-graph-wipe";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   --  U+2014, spelled in UTF-8 bytes.
   Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   Usage_Text : constant String :=
     "usage: synapse graph-wipe [--dry-run]" & LF;

   --  Writes the recovered notes into `scratchpad/` of the vault and returns
   --  the vault-relative path. Straight to the file system, since it has to
   --  succeed before the delete that follows it.
   function Stage_Preserved
     (Env : Environment; Ctx : Context.Context; Body_Text : String)
      return String
   is
      Vault : constant String := To_String (Ctx.Vault);
      Name  : constant String := To_String (Ctx.Namespace);
      Rel   : constant String :=
        "scratchpad/" & Name & " " & Dash &
        " preserved notes before full rebuild.md";
      Title : constant String :=
        Name & " " & Dash & " preserved notes before full rebuild";
   begin
      begin
         Ada.Directories.Create_Path (Vault & "/scratchpad");
      exception
         when others =>
            null;
      end;
      Adapters.File_Bytes.Write
        (Vault & "/" & Rel,
         "---" & LF & "title: """ & Title & """" & LF & "created: """ &
         Env.Clock.Timestamp & """" & LF & "---" & LF & LF & "# " & Title &
         LF & LF & "Hand-written `## Notes` content recovered from `synapse/" &
         Name &
         "` before it was wiped for a full rebuild. `/synapse-rebuild-full` " &
         "merges what it can back into the new nodes once the rebuild " &
         "completes; whatever is still here after that needs a manual look." &
         LF & LF & Body_Text);
      return Rel;
   end Stage_Preserved;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Dry_Run : Boolean := False;
   begin
      for Arg_Item of Args loop
         declare
            Arg : constant String := To_String (Arg_Item);
         begin
            if Arg = "--dry-run" then
               Dry_Run := True;
            elsif Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            else
               Complain (Env, Usage_Text);
               return 2;
            end if;
         end;
      end loop;

      declare
         Found : constant Context.Maybe_Context := Context.Resolve (Env, Prog);
      begin
         if not Found.Found then
            return 1;
         end if;
         declare
            Ctx     : Context.Context renames Found.Value;
            Dir     : constant String := To_String (Ctx.Dir);
            Abs_Dir : constant String := To_String (Ctx.Abs_Dir);
         begin
            if not Ada.Directories.Exists (Abs_Dir) then
               Complain
                 (Env,
                  Prog & ": no namespace at " & Dir &
                  " -- nothing to wipe (first build? use /synapse-init)" & LF);
               return 1;
            end if;

            declare
               Files     : constant Lists.Vector := Context.Node_Files (Ctx);
               Preserved : Unbounded_String;
               At_Risk   : Natural               := 0;
            begin
               for File of Files loop
                  declare
                     Text : constant Context.Maybe_Text :=
                       Context.Read_Node (Ctx, To_String (File));
                  begin
                     if Text.Found then
                        declare
                           Notes : constant String :=
                             Core.Emit.Notes_Body (To_String (Text.Value));
                           Title : constant String :=
                             Context.Strip_Md (To_String (File));
                        begin
                           if Notes /= "" then
                              At_Risk := At_Risk + 1;
                              Say
                                (Env,
                                 "at-risk" & HT & Title & HT &
                                 "has hand-written ## Notes content" & LF);
                              Append
                                (Preserved,
                                 "## " & Title & LF & LF & Notes & LF & LF);
                           end if;
                        end;
                     end if;
                  end;
               end loop;

               Say
                 (Env,
                  "namespace: " & Dir & " (" &
                  Core.Decimal_Image.Image (Natural (Files.Length)) &
                  " nodes, " & Core.Decimal_Image.Image (At_Risk) &
                  " with ## Notes content)" & LF);

               if Dry_Run then
                  Say (Env, "would-remove " & Dir & LF);
                  return 0;
               end if;

               if Length (Preserved) /= 0 then
                  Say
                    (Env,
                     "preserved -> " &
                     Stage_Preserved (Env, Ctx, To_String (Preserved)) & LF);
               end if;

               if not Support.Remove_Namespace
                   (Env, To_String (Ctx.Vault), Abs_Dir, Prog)
               then
                  return 1;
               end if;
               Say (Env, "removed " & Dir & LF);
               return 0;
            end;
         end;
      end;
   end Run;

end Synapse.Commands.Graph_Wipe;
