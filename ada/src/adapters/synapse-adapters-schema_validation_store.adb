with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Synapse.Adapters.Schema_Loader;
with Synapse.Core.Frontmatter.Edit;
with Synapse.Core.JSON;
with Synapse.Core.JSON_Logic;
with Synapse.Core.Note_Check;
with Synapse.Core.Note_Model;
with Synapse.Core.Note_Operators;
with Synapse.Core.Note_Schema;
with Synapse.Core.Schema_Rules;

package body Synapse.Adapters.Schema_Validation_Store is

   use Ada.Strings.Unbounded;
   use type Core.Note_Schema.Severity;
   use type Core.Note_Model.Field_Kind;
   use type Ada.Exceptions.Exception_Id;

   LF : constant Character := Character'Val (10);

   function Create
     (Inner : not null access Port.Store'Class;
      Vars  : not null access Ports.Variables.Variables'Class;
      Clock : not null access Ports.Clock.Clock'Class)
      return Validation_Store
   is (Port.Store with Inner => Inner, Vars => Vars, Clock => Clock);

   overriding
   function Read
     (S : in out Validation_Store; Node : String) return Port.Maybe_Text
   is (S.Inner.Read (Node));

   overriding
   function List (S : in out Validation_Store) return Core.Text_Lists.Vector
   is (S.Inner.List);

   overriding
   function Search
     (S : in out Validation_Store; Query : String)
      return Port.Hit_Vectors.Vector
   is (S.Inner.Search (Query));

   function Refused (Message : String) return Port.Write_Result
   is (Accepted  => False,
       Status    => Rejected,
       Body_Text => To_Unbounded_String (Message));

   --  The name Zig gives the error a rule raised.
   function Fault_Name (E : Ada.Exceptions.Exception_Occurrence) return String
   is (if Ada.Exceptions.Exception_Identity (E)
          = Core.JSON_Logic.Invalid_Arguments'Identity
       then "InvalidArguments"
       elsif Ada.Exceptions.Exception_Identity (E)
             = Core.JSON_Logic.Unknown_Operator'Identity
       then "UnknownOperator"
       elsif Ada.Exceptions.Exception_Identity (E)
             = Core.JSON_Logic.Pattern_Too_Complex'Identity
       then "PatternTooComplex"
       else Ada.Exceptions.Exception_Name (E));

   function Field_Name (N : Positive) return String
   is (if N = 1 then "note_id" else "task_id");

   --  The text of the identity field Field in Note, when it is a non-empty
   --  string.
   function Identity_In
     (Note : String; Field : String) return Port.Maybe_Text
   is
      Found : constant Core.Note_Model.Lookup :=
        Core.Note_Model.Lookup_Field (Note, Field);
   begin
      if Found.Found
        and then Found.Value.Kind = Core.Note_Model.String_Field
        and then Length (Found.Value.Text) > 0
      then
         return (Found => True, Text => Found.Value.Text);
      end if;
      return (Found => False);
   end Identity_In;

   --  The candidate's own note id (else task id), when another note than
   --  Candidate_Path holds the same one. Only asked for when the schema's
   --  rules consult `id_is_unique`.
   function Duplicate_Identity
     (S              : in out Validation_Store;
      Schema         : Core.JSON.Value;
      Candidate_Path : String;
      Candidate      : String) return Port.Maybe_Text
   is
      Wanted : Port.Maybe_Text;
   begin
      if not Core.Schema_Rules.Needs_Identity_Scan (Schema) then
         return (Found => False);
      end if;
      for N in 1 .. 2 loop
         Wanted := Identity_In (Candidate, Field_Name (N));
         exit when Wanted.Found;
      end loop;
      if not Wanted.Found then
         return (Found => False);
      end if;

      for Name of S.Inner.List loop
         if To_String (Name) /= Candidate_Path then
            declare
               Other : constant Port.Maybe_Text :=
                 S.Inner.Read (To_String (Name));
            begin
               if Other.Found then
                  for N in 1 .. 2 loop
                     declare
                        Held : constant Port.Maybe_Text :=
                          Identity_In (To_String (Other.Text), Field_Name (N));
                     begin
                        if Held.Found and then Held.Text = Wanted.Text then
                           return Wanted;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end if;
      end loop;
      return (Found => False);
   end Duplicate_Identity;

   overriding
   function Write
     (S : in out Validation_Store; Node, Content : String)
      return Port.Write_Result
   is
      Existing : constant Port.Maybe_Text := S.Inner.Read (Node);
      Old      : constant Core.Note_Check.Maybe_Text :=
        (if Existing.Found
         then Core.Note_Check.Schema_Id (To_String (Existing.Text))
         else (Found => False));
      Declared : constant Core.Note_Check.Maybe_Text :=
        Core.Note_Check.Schema_Id (Content);
   begin
      if not Declared.Found then
         if Old.Found then
            return Refused
              ("frontmatter.schema: cannot be removed from a "
               & "schema-declaring note");
         end if;
         return S.Inner.Write (Node, Content);
      end if;

      declare
         Schema_Id : constant String := To_String (Declared.Text);
         Mode      : constant Core.Note_Model.Mode :=
           (if not Existing.Found then Core.Note_Model.Create
            elsif not Old.Found or else Old.Text /= Declared.Text
            then Core.Note_Model.Migration
            else Core.Note_Model.Update);
      begin
         if not Schema_Loader.Is_Safe_Schema_Id (Schema_Id) then
            return Refused
              ("frontmatter.schema: unsafe identifier '" & Schema_Id & "'");
         end if;

         --  An update refreshes `updated` here, at the persistence boundary,
         --  so no caller has to read the note first to own the timestamp.
         declare
            Candidate : constant String :=
              (if Existing.Found
               then Core.Frontmatter.Edit.Set_Scalar
                      (Content, "updated", S.Clock.Timestamp)
               else Content);
            Loaded    : constant Schema_Loader.Load_Result :=
              Schema_Loader.Load_Schema (S.Vars.all, Schema_Id);
         begin
            if not Loaded.Ok then
               return Refused ("schema: " & To_String (Loaded.Fault));
            end if;

            declare
               Checked : constant Core.Note_Schema.Check_Result :=
                 Core.Note_Schema.Validate_Schema
                   (Loaded.Schema, Schema_Id, Core.Note_Operators.Operators);
            begin
               if not Checked.Valid then
                  return Refused (To_String (Checked.Message));
               end if;
            end;

            declare
               Ctx    : Core.Note_Model.Context;
               Stems  : constant Core.Schema_Rules.String_Array :=
                 Core.Schema_Rules.Needed_Vocabulary_Stems (Loaded.Schema);
               Dup    : Port.Maybe_Text;
            begin
               Ctx.Mode := Mode;
               Ctx.Has_Existing := Existing.Found;
               if Existing.Found then
                  Ctx.Existing := Existing.Text;
               end if;
               for Stem of Stems loop
                  declare
                     Text : constant Schema_Loader.Maybe_Text :=
                       Schema_Loader.Load_Vocabulary
                         (S.Vars.all, To_String (Stem) & ".conf");
                  begin
                     if Text.Found then
                        Ctx.Vocabularies.Append
                          (Core.Note_Model.Vocabulary_Source'
                             (Stem => Stem, Content => Text.Text));
                     end if;
                  end;
               end loop;
               if Mode in Core.Note_Model.Create | Core.Note_Model.Migration
               then
                  Dup :=
                    Duplicate_Identity (S, Loaded.Schema, Node, Candidate);
                  Ctx.Has_Duplicate := Dup.Found;
                  if Dup.Found then
                     Ctx.Duplicate_Identity := Dup.Text;
                  end if;
               end if;

               --  A rule called with the wrong arguments (a stale override of
               --  a schema, say) refuses the write like any violation, and
               --  does not end the process.
               declare
                  Checked : Core.Note_Schema.Check_Result;
               begin
                  Checked :=
                    Core.Note_Check.Validate_Note
                      (Loaded.Schema, Candidate, Node, Ctx);
                  if not Checked.Valid then
                     return Refused (To_String (Checked.Message));
                  end if;
               exception
                  when E : Core.JSON_Logic.Invalid_Arguments
                         | Core.JSON_Logic.Unknown_Operator
                         | Core.JSON_Logic.Pattern_Too_Complex =>
                     return Refused ("checks: " & Fault_Name (E));
               end;
            end;

            --  Only reached once the note validates: a refused write is not
            --  linted. A warning is advice and goes to standard error; an
            --  error finding refuses the write.
            declare
               Blocking : Unbounded_String;
            begin
               begin
                  for Finding of
                    Core.Note_Check.Lint_Note (Loaded.Schema, Candidate, Node)
                  loop
                     if Finding.Level = Core.Note_Schema.Error_Level then
                        if Length (Blocking) > 0 then
                           Append (Blocking, LF);
                        end if;
                        Append (Blocking, Finding.Message);
                     else
                        Ada.Text_IO.Put_Line
                          (Ada.Text_IO.Standard_Error,
                           "synapse: " & Node & ": "
                           & To_String (Finding.Message));
                     end if;
                  end loop;
               exception
                  when E : Core.JSON_Logic.Invalid_Arguments
                         | Core.JSON_Logic.Unknown_Operator
                         | Core.JSON_Logic.Pattern_Too_Complex =>
                     return Refused ("lints: " & Fault_Name (E));
               end;
               if Length (Blocking) > 0 then
                  return Refused (To_String (Blocking));
               end if;
            end;
            return S.Inner.Write (Node, Candidate);
         end;
      end;
   end Write;

end Synapse.Adapters.Schema_Validation_Store;
