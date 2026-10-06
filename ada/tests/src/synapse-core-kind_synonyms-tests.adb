with AUnit.Assertions;

package body Synapse.Core.Kind_Synonyms.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Kind (List : Rule_List; Spelling, Scope : String) return String is
      Found : constant Maybe_Kind := Kind_For (List, Spelling, Scope);
   begin
      return (if Found.Found then To_String (Found.Kind) else "none");
   end Kind;

   procedure An_Empty_List_Maps_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      List : constant Rule_List := Parse ("[]");
   begin
      Assert (Is_Empty (List), "empty");
      Assert (Kind (List, "widget", "scope.a") = "none", "unmapped");
      Assert (Is_Empty (Parse ("{}")), "an object is an empty list");
      Assert (Is_Empty (Parse ("""text""")), "so is a string");
   end An_Empty_List_Maps_Nothing;

   procedure An_Unscoped_Rule_Matches_Any_Grammar (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      List : constant Rule_List :=
        Parse ("[{""match"": ""widget"", ""kind"": ""gadget""}]");
   begin
      Assert (Kind (List, "widget", "scope.a") = "gadget", "one grammar");
      Assert (Kind (List, "widget", "scope.b") = "gadget", "another");
   end An_Unscoped_Rule_Matches_Any_Grammar;

   procedure Order_Decides_Precedence_Not_Specificity
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scoped_First  : constant Rule_List :=
        Parse
          ("[{""match"": ""widget"", ""scope"": ""scope.a"","
           & " ""kind"": ""one""}," &
           " {""match"": ""widget"", ""kind"": ""two""}]");
      General_First : constant Rule_List :=
        Parse
          ("[{""match"": ""widget"", ""kind"": ""two""}," &
           " {""match"": ""widget"", ""scope"": ""scope.a"","
           & " ""kind"": ""one""}]");
   begin
      Assert
        (Kind (Scoped_First, "widget", "scope.a") = "one",
         "a scoped rule wins when it comes first");
      Assert
        (Kind (Scoped_First, "widget", "scope.b") = "two",
         "a scope mismatch falls through");
      Assert
        (Kind (General_First, "widget", "scope.a") = "two",
         "a general rule first shadows a later scoped one");
   end Order_Decides_Precedence_Not_Specificity;

   procedure An_Unmapped_Spelling_Is_None_And_An_Empty_One_Is_A_Rule
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      List : constant Rule_List :=
        Parse ("[{""match"": """", ""kind"": ""variable""}]");
   begin
      Assert (Kind (List, "other", "s") = "none", "unmapped, not a guess");
      Assert
        (Natural (List.Rules.Length) = 1, "an empty match is not malformed");
      Assert
        (Kind (List, "", "s") = "variable", "and it matches the bare capture");
   end An_Unmapped_Spelling_Is_None_And_An_Empty_One_Is_A_Rule;

   procedure A_Malformed_Entry_Is_Skipped_And_The_Rest_Apply
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      List : constant Rule_List :=
        Parse
          ("[{""match"": ""a"", ""kind"": ""x""}, {""match"": ""bad""}," &
           " {""kind"": ""also-bad""}, ""not an object""," &
           " {""match"": 5, ""kind"": ""y""},"
           & " {""match"": ""e"", ""kind"": """"}," &
           " {""match"": ""f"", ""kind"": ""z"", ""scope"": """"}," &
           " {""match"": ""g"", ""kind"": ""w"", ""scope"": 3}]");
   begin
      Assert (Natural (List.Rules.Length) = 3, "three survive");
      Assert (Kind (List, "a", "s") = "x", "the first");
      Assert
        (Kind (List, "f", "any") = "z", "an empty scope means any grammar");
      Assert
        (Kind (List, "g", "any") = "w", "so does a scope that is not text");
      Assert (Kind (List, "e", "s") = "none", "an empty kind is no rule");
   end A_Malformed_Entry_Is_Skipped_And_The_Rest_Apply;

   procedure Text_That_Is_Not_Json_Is_Malformed (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         declare
            Ignore : constant Rule_List := Parse ("not json");
         begin
            null;
         end;
      exception
         when Malformed =>
            Raised := True;
      end;
      Assert (Raised, "a load error and not a silent empty list");
      Raised := False;
      begin
         declare
            Ignore : constant Rule_List := Parse ("");
         begin
            null;
         end;
      exception
         when Malformed =>
            Raised := True;
      end;
      Assert (Raised, "an empty file is not JSON");
   end Text_That_Is_Not_Json_Is_Malformed;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Kind_Synonyms");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Empty_List_Maps_Nothing'Access, "An empty list maps nothing");
      Register_Routine
        (T, An_Unscoped_Rule_Matches_Any_Grammar'Access,
         "An unscoped rule matches any grammar");
      Register_Routine
        (T, Order_Decides_Precedence_Not_Specificity'Access,
         "Order decides precedence, not specificity");
      Register_Routine
        (T, An_Unmapped_Spelling_Is_None_And_An_Empty_One_Is_A_Rule'Access,
         "An unmapped spelling is none and an empty one is a rule");
      Register_Routine
        (T, A_Malformed_Entry_Is_Skipped_And_The_Rest_Apply'Access,
         "A malformed entry is skipped and the rest apply");
      Register_Routine
        (T, Text_That_Is_Not_Json_Is_Malformed'Access,
         "Text that is not JSON is malformed");
   end Register_Tests;

end Synapse.Core.Kind_Synonyms.Tests;
