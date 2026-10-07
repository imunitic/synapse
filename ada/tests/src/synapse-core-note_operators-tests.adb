with Ada.Characters.Latin_1;

with AUnit.Assertions;
with Synapse.Core.Note_Model;
with Synapse.Core.Note_Schema;
with Synapse.Core.Schema_YAML;

package body Synapse.Core.Note_Operators.Tests is

   use AUnit.Assertions;
   use JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Ada.Characters.Latin_1.LF;

   --  JSON text with ' standing for ".
   function J (Text : String) return Value is
      Quoted : String := Text;
   begin
      for C of Quoted loop
         if C = ''' then
            C := '"';
         end if;
      end loop;
      declare
         Parsed : constant Parse_Result := Parse (Quoted);
      begin
         Assert (Parsed.Ok, "JSON parses: " & Text);
         return Parsed.Item;
      end;
   end J;

   function Eval (Rule : String; Data : Value) return Boolean is
     (JSON_Logic.Truthy
        (JSON_Logic.Evaluate
           (J (Rule), (Data => Data, others => <>), Operators)));

   function Note_Tree
     (Note      : String; Mode : Note_Model.Mode := Note_Model.Update;
      Duplicate : Boolean := False) return Value is
     (Note_Model.Data_Tree
        ("x.md", Note,
         (Mode => Mode, Has_Duplicate => Duplicate, others => <>)));

   function Fm (Body_Text : String) return String is
     ("---" & LF & "title: X" & LF & "---" & LF & Body_Text);

   Wrapped : constant String :=
     "# X" & LF & LF & "## Summary" & LF & "This is a sentence that got" & LF &
     "hard-wrapped across two lines." & LF;

   Clean : constant String :=
     "# X" & LF & LF & "## Summary" & LF &
     "This is one continuous line, exactly as the convention wants." & LF;

   ---------------------------------------------------------------------------

   procedure The_Set_Knows_Exactly_Its_Four_Operators
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Operators.Has_Operator ("on_create"), "on_create");
      Assert (Operators.Has_Operator ("no_hard_wrap"), "no_hard_wrap");
      Assert (Operators.Has_Operator ("hard_wrap"), "hard_wrap");
      Assert (Operators.Has_Operator ("no_stray_frontmatter"), "stray");
      Assert (not Operators.Has_Operator ("var"), "a built-in");
      Assert (not Operators.Has_Operator ("hard_wraps"), "a near miss");
      Assert (not Operators.Has_Operator ("On_Create"), "case matters");
      Assert (not Operators.Has_Operator (""), "empty");
      Assert
        (not JSON_Logic.Is_Built_In ("hard_wrap"),
         "and none of them is built in");
   end The_Set_Knows_Exactly_Its_Four_Operators;

   procedure On_Create_Delegates_When_Creating (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Eval
           ("{'on_create': {'var': 'n'}}",
            J ("{'is_create': true, 'n': true}")),
         "passes");
      Assert
        (not Eval
           ("{'on_create': {'var': 'n'}}",
            J ("{'is_create': true, 'n': false}")),
         "fails");
   end On_Create_Delegates_When_Creating;

   procedure On_Create_Skips_Its_Argument_Otherwise
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Rule : constant String :=
        "{'on_create': {'this_operator_does_not_exist': 1}}";
   begin
      --  The wrapped rule names an unknown operator: evaluating it would
      --  raise.
      Assert (Eval (Rule, J ("{'is_create': false}")), "not creating");
      Assert (Eval (Rule, J ("{}")), "no is_create at all");
      Assert (Eval (Rule, J ("[]")), "data that is not an object");
      Assert (Eval (Rule, J ("null")), "null data");
   end On_Create_Skips_Its_Argument_Otherwise;

   procedure On_Create_Reads_The_Real_Data_Tree (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Note   : constant String :=
        "---" & LF & "title: X" & LF & "created: ""2026-09-07T15:00:00Z""" &
        LF & "updated: ""2026-09-07T15:00:00Z""" & LF & "---" & LF & "# X" &
        LF;
      Unique : constant String := "{'on_create': {'var': 'id_is_unique'}}";
      Same   : constant String :=
        "{'on_create': {'==': [{'var': 'created_epoch'}," &
        " {'var': 'updated_epoch'}]}}";
   begin
      Assert
        (not Eval (Unique, Note_Tree (Note, Note_Model.Create, True)),
         "a duplicate on create");
      Assert
        (Eval (Unique, Note_Tree (Note, Note_Model.Create, False)),
         "unique on create");
      Assert
        (Eval (Unique, Note_Tree (Note, Note_Model.Update, True)),
         "not checked on update");
      Assert
        (not Eval (Unique, Note_Tree (Note, Note_Model.Migration, True)),
         "checked on migration");
      Assert
        (Eval (Same, Note_Tree (Note, Note_Model.Create)),
         "created equals updated on create");
      Assert
        (Eval (Same, Note_Tree (Note, Note_Model.Update)),
         "and is skipped on update");
   end On_Create_Reads_The_Real_Data_Tree;

   procedure No_Hard_Wrap_Reads_The_Body (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant String := "{'no_hard_wrap': {'var': 'body.prose'}}";
   begin
      Assert (not Eval (Rule, Note_Tree (Fm (Wrapped))), "wrapped");
      Assert (Eval (Rule, Note_Tree (Fm (Clean))), "clean");
      Assert
        (Eval
           (Rule,
            Note_Tree
              (Fm
                 ("# X" & LF & LF & "## Summary" & LF & "```" & LF & "two" &
                  LF & "lines" & LF & "```" & LF))),
         "fenced code");
      Assert
        (Eval
           (Rule,
            Note_Tree
              (Fm
                 ("# X" & LF & LF & "## Summary" & LF & "| a | b |" & LF &
                  "| c | d |" & LF & LF & "- item one" & LF &
                  "  a continuation" & LF & "  and another" & LF))),
         "tables and list continuations");
   end No_Hard_Wrap_Reads_The_Body;

   procedure Text_That_Is_Not_A_String_Is_Fine (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Data : constant Value := J ("{'n': 5, 'l': ['a', 'b']}");
   begin
      Assert (Eval ("{'no_hard_wrap': {'var': 'n'}}", Data), "number");
      Assert (Eval ("{'no_hard_wrap': {'var': 'missing'}}", Data), "missing");
      Assert (Eval ("{'no_hard_wrap': {'var': 'l'}}", Data), "list");
      Assert (Eval ("{'hard_wrap': [{'var': 'n'}, 20]}", Data), "hard_wrap");
      Assert (Eval ("{'no_stray_frontmatter': {'var': 'n'}}", Data), "stray");
   end Text_That_Is_Not_A_String_Is_Fine;

   procedure Operators_Compose_With_Built_Ins (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Note : constant String :=
        "---" & LF & "title: X" & LF & "status: Ready" & LF & "---" & LF &
        "# X" & LF & LF & "## Summary" & LF & "One continuous line." & LF;
      Tree : constant Value  := Note_Tree (Note);
   begin
      Assert
        (Eval
           ("{'and': [{'no_hard_wrap': {'var': 'body.prose'}}," &
            " {'==': [{'var': 'frontmatter.status'}, 'Ready']}]}",
            Tree),
         "under and");
      Assert
        (not Eval ("{'!': {'no_hard_wrap': {'var': 'body.prose'}}}", Tree),
         "under not");
      Assert
        (Eval
           ("{'or': [{'no_hard_wrap': {'var': 'body.prose'}}," &
            " {'this_is_not_evaluated': 1}]}",
            Tree),
         "under or, short-circuiting");
   end Operators_Compose_With_Built_Ins;

   procedure Hard_Wrap_Checks_The_Width (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant String := "{'hard_wrap': [{'var': 'body.prose'}, 20]}";

      function Body_Of (Text : String) return Value is
        (Note_Tree (Fm ("# X" & LF & LF & "## Summary" & LF & Text)));
   begin
      Assert
        (Eval
           (Rule,
            Body_Of ("This is a test of hard" & LF & "wrap logic here." & LF)),
         "greedy wrapped");
      Assert
        (not Eval
           (Rule,
            Body_Of ("This is a test of" & LF & "hard wrap logic here." & LF)),
         "reflowed too early");
      Assert
        (not Eval
           (Rule,
            Body_Of ("This is a test of hard wrap" & LF & "logic here." & LF)),
         "padded past the boundary");
      Assert
        (Eval
           (Rule,
            Body_Of
              ("```" & LF & "not wrapped" & LF & "at all" & LF & "```" & LF)),
         "fenced");
   end Hard_Wrap_Checks_The_Width;

   procedure Bad_Arguments_Raise (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Tree : constant Value := Note_Tree (Fm (Clean));

      procedure Must_Raise (Rule : String) is
         Raised : Boolean := False;
      begin
         begin
            Assert (Eval (Rule, Tree) or else True, "unreachable");
         exception
            when JSON_Logic.Invalid_Arguments =>
               Raised := True;
         end;
         Assert (Raised, "Invalid_Arguments: " & Rule);
      end Must_Raise;
   begin
      Must_Raise ("{'hard_wrap': [{'var': 'body.prose'}]}");
      Must_Raise ("{'hard_wrap': [{'var': 'body.prose'}, 0]}");
      Must_Raise ("{'hard_wrap': [{'var': 'body.prose'}, -3]}");
      Must_Raise ("{'hard_wrap': [{'var': 'body.prose'}, '20']}");
      Must_Raise ("{'hard_wrap': [{'var': 'body.prose'}, 2.5]}");
      Must_Raise ("{'hard_wrap': [{'var': 'body.prose'}, null]}");
      Must_Raise ("{'hard_wrap': []}");
      Must_Raise ("{'no_hard_wrap': []}");
      Must_Raise ("{'on_create': []}");
      Must_Raise ("{'no_stray_frontmatter': []}");
      Assert
        (Eval ("{'hard_wrap': [5, 0]}", Tree),
         "a text that is not a string is checked first");
   end Bad_Arguments_Raise;

   procedure Stray_Frontmatter_Is_Found_In_The_Body
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Rule : constant String :=
        "{'no_stray_frontmatter': {'var': 'body.prose'}}";
   begin
      Assert
        (not Eval
           (Rule,
            Note_Tree
              (Fm
                 ("# X" & LF & LF & "Some prose." & LF & LF & "---" & LF &
                  "leftover: fragment" & LF & "---" & LF & LF & "More prose." &
                  LF))),
         "a pasted block");
      Assert
        (Eval
           (Rule,
            Note_Tree
              (Fm
                 ("# X" & LF & LF & "Above." & LF & LF & "---" & LF & LF &
                  "Below." & LF))),
         "a lone divider");
      Assert
        (Eval
           (Rule,
            Note_Tree
              (Fm
                 ("# X" & LF & LF & "Example:" & LF & LF & "```" & LF & "---" &
                  LF & "key: value" & LF & "---" & LF & "```" & LF))),
         "quoted in a fence");
      Assert
        (Eval (Rule, Note_Tree (Fm ("# X" & LF & LF & "Prose." & LF))),
         "clean");
      Assert
        (Eval (Rule, Note_Tree ("# No frontmatter" & LF)), "no frontmatter");
   end Stray_Frontmatter_Is_Found_In_The_Body;

   procedure Schemas_Using_The_Operators_Validate_Only_With_The_Set
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Source : constant String                   :=
        "schema: synapse-note-schema/v1" & LF & "id: t/v1" & LF &
        "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF &
        "      type: string" & LF & "body:" & LF & "  h1:" & LF &
        "    required: false" & LF & "checks:" & LF & "  - on_create:" & LF &
        "      var: id_is_unique" & LF & "lints:" & LF & "  - no_hard_wrap:" &
        LF & "      var: body.prose" & LF & "    severity: warn" & LF &
        "  - hard_wrap:" & LF & "      - var: body.prose" & LF & "      - 80" &
        LF & "    severity: ignore" & LF & "  - no_stray_frontmatter:" & LF &
        "      var: body.prose" & LF & "    severity: error" & LF;
      Parsed : constant Schema_YAML.Parse_Result := Schema_YAML.Parse (Source);
   begin
      Assert
        (Schema_YAML.Parse_Results.Is_Success (Parsed), "the schema parses");
      Assert
        (Note_Schema.Check_Results.Is_Success
           (Note_Schema.Validate_Schema
              (Schema_YAML.Parse_Results.Value (Parsed), "t/v1", Operators)),
         "valid with the set");
      Assert
        (not Note_Schema.Check_Results.Is_Success
           (Note_Schema.Validate_Schema
              (Schema_YAML.Parse_Results.Value (Parsed), "t/v1")),
         "unknown without it");
   end Schemas_Using_The_Operators_Validate_Only_With_The_Set;

   ---------------------------------------------------------------------------

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Note_Operators");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Set_Knows_Exactly_Its_Four_Operators'Access,
         "The set knows exactly its four operators");
      Register_Routine
        (T, On_Create_Delegates_When_Creating'Access,
         "on_create delegates when creating");
      Register_Routine
        (T, On_Create_Skips_Its_Argument_Otherwise'Access,
         "on_create skips its argument otherwise");
      Register_Routine
        (T, On_Create_Reads_The_Real_Data_Tree'Access,
         "on_create reads the real data tree");
      Register_Routine
        (T, No_Hard_Wrap_Reads_The_Body'Access, "no_hard_wrap reads the body");
      Register_Routine
        (T, Text_That_Is_Not_A_String_Is_Fine'Access,
         "Text that is not a string is fine");
      Register_Routine
        (T, Operators_Compose_With_Built_Ins'Access,
         "Operators compose with built-ins");
      Register_Routine
        (T, Hard_Wrap_Checks_The_Width'Access, "hard_wrap checks the width");
      Register_Routine (T, Bad_Arguments_Raise'Access, "Bad arguments raise");
      Register_Routine
        (T, Stray_Frontmatter_Is_Found_In_The_Body'Access,
         "Stray frontmatter is found in the body");
      Register_Routine
        (T, Schemas_Using_The_Operators_Validate_Only_With_The_Set'Access,
         "Schemas using the operators validate only with the set");
   end Register_Tests;

end Synapse.Core.Note_Operators.Tests;
