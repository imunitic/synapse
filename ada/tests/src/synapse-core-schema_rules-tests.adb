with Ada.Characters.Latin_1;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Interfaces;

with Synapse.Core.JSON_Logic;
with Synapse.Core.Schema_YAML;

package body Synapse.Core.Schema_Rules.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Ada.Characters.Latin_1.LF;

   --  A schema document's value, from YAML text.
   function Yaml (Source : String) return Value is
      R : constant Schema_YAML.Parse_Result := Schema_YAML.Parse (Source);
   begin
      Assert (R.Ok, "the YAML parses: " & Source);
      return R.Root;
   end Yaml;

   function Json_Of (Text : String) return Value is
      R : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (R.Ok, "the JSON parses: " & Text);
      return R.Item;
   end Json_Of;

   function Rule_Of (V : Value) return Value is
      R : constant Rule_Result := To_Rule (V);
   begin
      Assert (R.Ok, "the rule converts");
      return R.Rule;
   end Rule_Of;

   function Names (List : String_Array) return String is
      Result : Unbounded_String;
   begin
      for I in List'Range loop
         Append (Result, (if I = List'First then "" else ",")
                         & To_String (List (I)));
      end loop;
      return To_String (Result);
   end Names;

   ---------------------------------------------------------------------------
   --  Conversion
   ---------------------------------------------------------------------------

   procedure Scalars_Pass_Through_Unchanged (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (As_String (Rule_Of (Make_String ("REVIEW"))) = "REVIEW",
         "string");
      Assert (As_Integer (Rule_Of (Make_Integer (42))) = 42, "integer");
      Assert (As_Boolean (Rule_Of (Make_Boolean (True))), "boolean");
   end Scalars_Pass_Through_Unchanged;

   procedure A_Bare_Null_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not To_Rule (Null_Value).Ok, "a null by itself");
      Assert (not To_Rule (Json_Of ("{""and"": [1, null]}")).Ok,
              "a null inside an array");
      Assert (not To_Rule (Json_Of ("{""a"": 1, ""b"": null}")).Ok,
              "a null inside a multi-key object");
   end A_Bare_Null_Is_Refused;

   procedure A_List_Converts_Element_By_Element
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Converted : constant Value :=
        Rule_Of (Json_Of ("[""a"", {""eq"": [1, 2]}]"));
   begin
      Assert (Length (Converted) = 2, "two elements");
      Assert
        (Has_Member (Element (Converted, 2), "=="),
         "the second converted");
   end A_List_Converts_Element_By_Element;

   procedure A_Word_Alias_Is_Renamed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Key_After (Word : String) return String is
         Converted : constant Value :=
           Rule_Of (Json_Of ("{""" & Word & """: [1, 2]}"));
      begin
         return Member_Key (Converted, 1);
      end Key_After;
   begin
      Assert (Key_After ("eq") = "==", "eq");
      Assert (Key_After ("ne") = "!=", "ne");
      Assert (Key_After ("lt") = "<", "lt");
      Assert (Key_After ("lte") = "<=", "lte");
      Assert (Key_After ("gt") = ">", "gt");
      Assert (Key_After ("gte") = ">=", "gte");
      Assert (Key_After ("not") = "!", "not");
      Assert (Key_After ("and") = "and", "an operator that is already a word");
      Assert (Key_After ("var") = "var", "var");
      Assert
        (Key_After ("no_hard_wrap") = "no_hard_wrap",
         "a custom operator");
   end A_Word_Alias_Is_Renamed;

   procedure A_Multi_Key_Object_Is_Data (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Converted : constant Value :=
        Rule_Of (Json_Of ("{""eq"": ""x"", ""not"": ""y""}"));
   begin
      Assert
        (Has_Member (Converted, "eq") and then Has_Member (Converted, "not"),
              "the keys are untouched");
      Assert
        (not Has_Member (Converted, "==")
         and then not Has_Member (Converted, "!"),
              "and nothing was renamed");
   end A_Multi_Key_Object_Is_Data;

   procedure A_Checks_Entry_Evaluates_Like_The_Symbolic_Form
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Where : constant JSON_Logic.Scope :=
        (Data => Json_Of ("{""frontmatter"": {""status"": ""REVIEW""}}"),
         others => <>);
      With_Alias : constant Value :=
        Rule_Of
          (Json_Of
             ("{""eq"": [{""var"": ""frontmatter.status""}, ""REVIEW""]}"));
      Symbolic : constant Value :=
        Json_Of ("{""=="": [{""var"": ""frontmatter.status""}, ""REVIEW""]}");
   begin
      Assert (With_Alias = Symbolic, "the same tree");
      Assert (JSON_Logic.Truthy (JSON_Logic.Evaluate (With_Alias, Where)),
              "and it evaluates true");
   end A_Checks_Entry_Evaluates_Like_The_Symbolic_Form;

   procedure Real_Schema_YAML_Converts_And_Evaluates
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Schema : constant Value :=
        Yaml ("checks:" & LF & "  - eq:" & LF
          & "      - var: frontmatter.status"
              & LF & "      - REVIEW" & LF & "  - not_a_real_key: ignored"
              & LF);
      Where  : constant JSON_Logic.Scope :=
        (Data => Json_Of ("{""frontmatter"": {""status"": ""REVIEW""}}"),
         others => <>);
   begin
      Assert (JSON_Logic.Truthy
                (JSON_Logic.Evaluate
                    (Rule_Of
                       (Element (Member_Value (Schema, "checks"), 1)),
                     Where)),
              "end to end through parse, convert and evaluate");
   end Real_Schema_YAML_Converts_And_Evaluates;

   procedure Deeper_Nesting_Converts (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Schema : constant Value :=
        Yaml ("checks:" & LF & "  - and:" & LF
          & "      - no_hard_wrap: body.prose"
              & LF & "      - eq:" & LF & "          - var: frontmatter.status"
              & LF & "          - Ready" & LF);
      Rule   : constant Value :=
        Rule_Of (Element (Member_Value (Schema, "checks"), 1));
   begin
      Assert (Has_Member (Rule, "and"), "the outer operator");
      Assert (Has_Member (Element (Member_Value (Rule, "and"), 2), "=="),
              "the nested alias");
   end Deeper_Nesting_Converts;

   ---------------------------------------------------------------------------
   --  Scans
   ---------------------------------------------------------------------------

   procedure Vocabulary_Stems_Are_Found_Nested (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant Value :=
        Rule_Of
          (Element
             (Member_Value
                (Yaml ("checks:" & LF & "  - all:" & LF
                       & "      - var: frontmatter.tags" & LF & "      - in:"
                       & LF
                       & "          - var: """"" & LF
                       & "          - var: vocabularies.synapse-tag-vocabulary"
                       & LF),
                 "checks"), 1));
   begin
      Assert (Names (Vocabulary_Stems (Rule)) = "synapse-tag-vocabulary",
              "one stem, nested inside all and in");
   end Vocabulary_Stems_Are_Found_Nested;

   procedure Distinct_Stems_Keep_Their_First_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Rule : constant Value :=
        Rule_Of
          (Element
             (Member_Value
                (Yaml ("checks:" & LF & "  - or:" & LF & "      - in:" & LF
                       & "          - var: vocabularies.a" & LF
                       & "          - var: frontmatter.x" & LF & "      - in:"
                       & LF
                       & "          - var: vocabularies.b" & LF
                       & "          - var: frontmatter.y" & LF & "      - in:"
                       & LF
                       & "          - var: vocabularies.a" & LF
                       & "          - var: frontmatter.z" & LF),
                 "checks"), 1));
   begin
      Assert
        (Names (Vocabulary_Stems (Rule)) = "a,b",
         "no duplicates, first seen");
   end Distinct_Stems_Keep_Their_First_Order;

   procedure No_Vocabulary_Means_No_Stems (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant Value :=
        Rule_Of
          (Json_Of
             ("{""eq"": [{""var"": ""frontmatter.status""}, ""REVIEW""]}"));
   begin
      Assert (Vocabulary_Stems (Rule)'Length = 0, "none");
      Assert
        (Vocabulary_Stems
           (Rule_Of (Json_Of ("{""var"": ""vocabularies.""}")))
              (1) = To_Unbounded_String (""), "an empty stem is still a stem");
   end No_Vocabulary_Means_No_Stems;

   procedure Only_A_One_Key_Var_Object_Counts (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Vocabulary_Stems
                (Json_Of
                   ("{""var"": ""vocabularies.x"", ""other"": 1}"))'Length = 0,
              "a two-key object is data");
      Assert (Vocabulary_Stems (Json_Of ("{""var"": 5}"))'Length = 0,
              "a non-string path");
      Assert
        (References_Var
           (Json_Of ("{""and"": [{""var"": ""id_is_unique""}]}"),
                              "id_is_unique"), "a var inside and");
      Assert (not References_Var (Json_Of ("{""var"": ""id_is_unique_not""}"),
                                  "id_is_unique"), "an exact match only");
      Assert
        (not References_Var (Json_Of ("[1, ""var""]"), "var"),
         "no var call");
   end Only_A_One_Key_Var_Object_Counts;

   procedure Entry_Shapes_Name_The_Rule_Key (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Shape (Text : String) return Entry_Shape
      is (Shape_Of (Json_Of (Text)));
   begin
      declare
         S : constant Entry_Shape :=
           Shape ("{""eq"": [1, 2], ""severity"": ""warn""}");
      begin
         Assert (S.Is_Rule and then To_String (S.Key) = "eq", "one rule key");
         Assert (not S.Message_Invalid, "no message to complain about");
      end;
      declare
         S : constant Entry_Shape :=
           Shape ("{""no_hard_wrap"": 1, ""message"": ""words""}");
      begin
         Assert (S.Is_Rule and then S.Message_Present, "a string message");
      end;
      Assert (Shape ("{""eq"": 1, ""message"": 5}").Message_Invalid,
              "a message that is not a string");
      Assert (not Shape ("{""eq"": 1, ""and"": 2}").Is_Rule, "two rule keys");
      Assert (not Shape ("{""severity"": ""warn""}").Is_Rule, "no rule key");
      Assert (not Shape ("[1]").Is_Rule, "not a mapping");
      Assert
        (Has_Member
           (Rule_Object (Shape ("{""eq"": 1, ""message"": ""m""}")),
                          "eq"), "the rule as a one-key object");
   end Entry_Shapes_Name_The_Rule_Key;

   procedure Schemas_Report_What_They_Need (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Schema : constant Value :=
        Yaml ("checks:" & LF & "  - on_create:" & LF
          & "      var: id_is_unique" & LF
              & "  - all:" & LF & "      - var: frontmatter.tags" & LF
              & "      - in:"
              & LF & "          - var: """"" & LF
              & "          - var: vocabularies.tags" & LF
              & "lints:" & LF & "  - eq:" & LF
              & "      - var: vocabularies.more" & LF
              & "      - 1" & LF & "    severity: warn" & LF);
      Plain  : constant Value := Yaml ("checks: []" & LF);
   begin
      Assert (Names (Needed_Vocabulary_Stems (Schema)) = "tags,more",
              "stems from checks, then lints");
      Assert (Needs_Identity_Scan (Schema), "id_is_unique is referenced");
      Assert (Needed_Vocabulary_Stems (Plain)'Length = 0, "nothing to read");
      Assert (not Needs_Identity_Scan (Plain), "nothing to scan");
      Assert (not Needs_Identity_Scan (Yaml ("a: 1"
        & LF)), "no checks at all");
   end Schemas_Report_What_They_Need;

   ---------------------------------------------------------------------------
   --  Properties
   ---------------------------------------------------------------------------

   Seed : Interfaces.Unsigned_64 := 20_261_013;

   function Next (Limit : Positive) return Natural is
      use type Interfaces.Unsigned_64;
   begin
      Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural ((Seed / 2**20) mod Interfaces.Unsigned_64 (Limit));
   end Next;

   function Operator_Name return String
   is (case Next (8) is
         when 0 => "eq",
         when 1 => "ne",
         when 2 => "lt",
         when 3 => "lte",
         when 4 => "gt",
         when 5 => "gte",
         when 6 => "not",
         when others => "and");

   --  Rules built from operators in word form, with scalars at the leaves.
   function Random_Rule (Depth : Natural) return Value is
   begin
      if Depth >= 3 or else Next (3) = 0 then
         case Next (3) is
            when 0 =>
               return Make_String ("s" & Natural'Image (Next (9)) (2 .. 2));

            when 1 =>
               return Make_Integer (Long_Long_Integer (Next (9)));

            when others =>
               return Make_Boolean (Next (2) = 0);
         end case;
      end if;
      case Next (3) is
         when 0 =>
            return Make_Object
              ([(To_Unbounded_String (Operator_Name),
                 Make_Array
                   ([Random_Rule (Depth + 1), Random_Rule (Depth + 1)]))]);

         when 1 =>
            return
              Make_Array
                ([Random_Rule (Depth + 1), Random_Rule (Depth + 1)]);

         when others =>
            return Make_Object
              ([(To_Unbounded_String ("a"), Random_Rule (Depth + 1)),
                (To_Unbounded_String ("eq"), Random_Rule (Depth + 1))]);
      end case;
   end Random_Rule;

   procedure Conversion_Is_Idempotent_And_Total_On_Null_Free_Trees
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for I in 1 .. 3_000 loop
         declare
            Source : constant Value := Random_Rule (0);
            Once   : constant Rule_Result := To_Rule (Source);
         begin
            if not Once.Ok then
               Assert (False, "case" & I'Image
                 & ": a null-free tree was refused");
            else
               declare
                  Again : constant Rule_Result := To_Rule (Once.Rule);
               begin
                  --  Symbols are not aliases, so a second pass changes nothing
                  --  except a one-key object whose key is `not` or the like
                  --  that is not a symbol; there are none left.
                  if not Again.Ok or else Again.Rule /= Once.Rule then
                     Assert (False, "case" & I'Image
                       & ": converting twice differs: "
                             & JSON.To_String (Source));
                  end if;
               end;
            end if;
         end;
      end loop;
   end Conversion_Is_Idempotent_And_Total_On_Null_Free_Trees;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Schema_Rules");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Scalars_Pass_Through_Unchanged'Access,
         "Scalars pass through unchanged");
      Register_Routine
        (T, A_Bare_Null_Is_Refused'Access, "A bare null is refused");
      Register_Routine
        (T, A_List_Converts_Element_By_Element'Access,
         "A list converts element by element");
      Register_Routine
        (T, A_Word_Alias_Is_Renamed'Access, "A word alias is renamed");
      Register_Routine
        (T, A_Multi_Key_Object_Is_Data'Access, "A multi-key object is data");
      Register_Routine
        (T, A_Checks_Entry_Evaluates_Like_The_Symbolic_Form'Access,
         "A checks entry evaluates like the symbolic form");
      Register_Routine
        (T, Real_Schema_YAML_Converts_And_Evaluates'Access,
         "Real schema YAML converts and evaluates");
      Register_Routine
        (T, Deeper_Nesting_Converts'Access, "Deeper nesting converts");
      Register_Routine
        (T, Vocabulary_Stems_Are_Found_Nested'Access,
         "Vocabulary stems are found nested");
      Register_Routine
        (T, Distinct_Stems_Keep_Their_First_Order'Access,
         "Distinct stems keep their first order");
      Register_Routine
        (T, No_Vocabulary_Means_No_Stems'Access,
         "No vocabulary means no stems");
      Register_Routine
        (T, Only_A_One_Key_Var_Object_Counts'Access,
         "Only a one-key var object counts");
      Register_Routine
        (T, Entry_Shapes_Name_The_Rule_Key'Access,
         "Entry shapes name the rule key");
      Register_Routine
        (T, Schemas_Report_What_They_Need'Access,
         "Schemas report what they need");
      Register_Routine
        (T, Conversion_Is_Idempotent_And_Total_On_Null_Free_Trees'Access,
         "Conversion is idempotent on null-free trees");
   end Register_Tests;

end Synapse.Core.Schema_Rules.Tests;
