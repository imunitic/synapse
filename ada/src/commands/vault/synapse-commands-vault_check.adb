with Ada.Strings.Unbounded;

with Synapse.Adapters.Schema_Loader;
with Synapse.Commands.Vault_Support;
with Synapse.Commands.Vault_Usage;
with Synapse.Core.JSON_Logic;
with Synapse.Core.Note_Check;
with Synapse.Core.Note_Model;
with Synapse.Core.Note_Operators;
with Synapse.Core.Note_Schema;
with Synapse.Core.Schema_Rules;
with Synapse.Ports.Store;
with Synapse.Core.Decimal_Image;

package body Synapse.Commands.Vault_Check is

   use Ada.Strings.Unbounded;

   package Port renames Synapse.Ports.Store;
   package Loader renames Synapse.Adapters.Schema_Loader;
   package Support renames Synapse.Commands.Vault_Support;

   Prog : constant String    := "synapse-vault";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Vault : Unbounded_String;
      Found : Boolean;
      Stack : Support.Store_Resolve.Stack;
      Ok    : Boolean;
   begin
      if not Args.Is_Empty then
         return
           Support.Help_Or_Usage
             (Env, To_String (Args (1)), Vault_Usage.Check);
      end if;
      Support.Find_Vault (Env, Prog, Vault, Found);
      if not Found then
         return 1;
      end if;
      Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
      if not Ok then
         return 1;
      end if;

      declare
         Store : constant not null access Port.Store'Class :=
           Support.Store_Resolve.Store (Stack);
         Names : constant Lists.Vector                     := Store.List;

         --  Each vocabulary file is read once however many notes need it.
         Cache : Core.Note_Model.Vocabulary_Vectors.Vector;

         Declared, Conformant, Legacy, Violations : Natural := 0;
         Lint_Notes, Lint_Findings                : Natural := 0;
         Rows                                     : Unbounded_String;
         Lint                                     : Unbounded_String;

         procedure Violation (Name, Message : String) is
         begin
            Append (Rows, Name & HT & Message & LF);
            Violations := Violations + 1;
         end Violation;

         function Cached (Stem : String) return Boolean is
         begin
            for Item of Cache loop
               if To_String (Item.Stem) = Stem then
                  return True;
               end if;
            end loop;
            return False;
         end Cached;

         procedure Check (Name : String; Text : String) is
            Declares : constant Core.Note_Check.Maybe_Text :=
              Core.Note_Check.Schema_Id (Text);
         begin
            if not Declares.Found then
               Legacy := Legacy + 1;
               return;
            end if;
            Declared := Declared + 1;
            declare
               Id     : constant String := To_String (Declares.Value);
               Loaded : constant Loader.Load_Result :=
                 Loader.Load_Schema (Env.Vars.all, Id);
            begin
               if not Adapters.Schema_Loader.Load_Results.Is_Success (Loaded)
               then
                  Violation
                    (Name,
                     To_String
                       (Adapters.Schema_Loader.Load_Results.Error (Loaded)));
                  return;
               end if;
               declare
                  Valid : constant Core.Note_Schema.Check_Result :=
                    Core.Note_Schema.Validate_Schema
                      (Adapters.Schema_Loader.Load_Results.Value (Loaded), Id,
                       Core.Note_Operators.Operators);
               begin
                  if not Core.Note_Schema.Check_Results.Is_Success (Valid) then
                     Violation
                       (Name,
                        To_String
                          (Core.Note_Schema.Check_Results.Error (Valid)));
                     return;
                  end if;
               end;

               declare
                  Ctx : Core.Note_Model.Context;
               begin
                  Ctx.Mode         := Core.Note_Model.Update;
                  Ctx.Has_Existing := True;
                  Ctx.Existing     := To_Unbounded_String (Text);
                  for Stem of Core.Schema_Rules.Needed_Vocabulary_Stems
                    (Adapters.Schema_Loader.Load_Results.Value (Loaded))
                  loop
                     if not Cached (To_String (Stem)) then
                        declare
                           File : constant Loader.Maybe_Text :=
                             Loader.Load_Vocabulary
                               (Env.Vars.all, To_String (Stem) & ".conf");
                        begin
                           if File.Found then
                              Cache.Append
                                (Core.Note_Model.Vocabulary_Source'
                                   (Stem => Stem, Content => File.Value));
                           end if;
                        end;
                     end if;
                     for Item of Cache loop
                        if Item.Stem = Stem then
                           Ctx.Vocabularies.Append (Item);
                        end if;
                     end loop;
                  end loop;

                  --  A rule called with the wrong arguments (a stale override
                  --  of a schema) is one note's violation, not the end of the
                  --  sweep.
                  begin
                     declare
                        Checked : constant Core.Note_Schema.Check_Result :=
                          Core.Note_Check.Validate_Note
                            (Adapters.Schema_Loader.Load_Results.Value
                               (Loaded),
                             Text, Name, Ctx);
                     begin
                        if not Core.Note_Schema.Check_Results.Is_Success
                            (Checked)
                        then
                           Violation
                             (Name,
                              To_String
                                (Core.Note_Schema.Check_Results.Error
                                   (Checked)));
                           return;
                        end if;
                     end;
                  exception
                     when E : Core.JSON_Logic.Invalid_Arguments
                       | Core.JSON_Logic.Unknown_Operator
                       | Core.JSON_Logic.Pattern_Too_Complex =>
                        Violation (Name, Core.Note_Check.Fault_Name (E));
                        return;
                  end;
                  Conformant := Conformant + 1;

                  --  Advice only: never counted as a violation, never in the
                  --  exit code.
                  begin
                     declare
                        Findings :
                          constant Core.Note_Check.Finding_Vectors.Vector :=
                          Core.Note_Check.Lint_Note
                            (Adapters.Schema_Loader.Load_Results.Value
                               (Loaded),
                             Text, Name);
                     begin
                        if not Findings.Is_Empty then
                           Lint_Notes := Lint_Notes + 1;
                        end if;
                        for Finding of Findings loop
                           Append
                             (Lint,
                              Name & HT & To_String (Finding.Message) & LF);
                           Lint_Findings := Lint_Findings + 1;
                        end loop;
                     end;
                  exception
                     when E : Core.JSON_Logic.Invalid_Arguments
                       | Core.JSON_Logic.Unknown_Operator
                       | Core.JSON_Logic.Pattern_Too_Complex =>
                        Append
                          (Lint,
                           Name & HT & Core.Note_Check.Fault_Name (E) & LF);
                        Lint_Notes    := Lint_Notes + 1;
                        Lint_Findings := Lint_Findings + 1;
                  end;
               end;
            end;
         end Check;
      begin
         for Name of Names loop
            declare
               Got : constant Port.Maybe_Text := Store.Read (To_String (Name));
            begin
               if Got.Found then
                  Check (To_String (Name), To_String (Got.Value));
               end if;
            exception
               when Port.Store_Failure | Port.Unsafe_Node
                 | Port.Node_Not_Found =>
                  null;
            end;
         end loop;

         Append
           (Rows,
            Core.Decimal_Image.Image (Natural (Names.Length)) & " notes: " &
            Core.Decimal_Image.Image (Declared) & " schema-declaring (" &
            Core.Decimal_Image.Image (Conformant) & " conformant, " &
            Core.Decimal_Image.Image (Violations) & " violations), " &
            Core.Decimal_Image.Image (Legacy) & " legacy" & LF);
         if Lint_Findings > 0 then
            Append
              (Rows,
               LF & "Lint (advisory, " &
               Core.Decimal_Image.Image (Lint_Findings) &
               " finding(s) across " & Core.Decimal_Image.Image (Lint_Notes) &
               " note(s)):" & LF);
            Append (Rows, Lint);
         end if;
         Say (Env, To_String (Rows));
         return (if Violations = 0 then 0 else 1);
      end;
   exception
      when Port.Store_Failure | Port.Unsafe_Node | Port.Node_Not_Found =>
         Complain (Env, Prog & ": list failed" & LF);
         return 1;
   end Run;

end Synapse.Commands.Vault_Check;
