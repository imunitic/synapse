with Ada.Strings.Unbounded;

with AUnit.Assertions;
with Synapse.Core.Optional_Text;

package body Synapse.Core.Field_Rules.Tests is

   use AUnit.Assertions;
   use JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Json_Of (Text : String) return Value is
      R : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (R.Ok, "the JSON parses: " & Text);
      return R.Item;
   end Json_Of;

   --  The problem Check_Value reports for Given under the rule Rule_Text,
   --  or "" when it reports none.
   function Problem (Rule_Text : String; Given : Value) return String is
      Found : constant Optional_Text.Option :=
        Check_Value ("input.x", Json_Of (Rule_Text), Given);
   begin
      return
        (if Found.Found then Ada.Strings.Unbounded.To_String (Found.Value)
         else "");
   end Problem;

   procedure Expect (Got, Wanted, What : String) is
   begin
      Assert (Got = Wanted, What & ": got """ & Got & """");
   end Expect;

   procedure Type_Is_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Problem ("{""type"": ""string""}", Make_String ("a")), "",
         "a string");
      Expect
        (Problem ("{""type"": ""boolean""}", Make_String ("true")),
         "input.x: expected boolean", "a string is not a boolean");
      Expect
        (Problem ("{""type"": ""list""}", Json_Of ("[""a""]")), "",
         "a list");
      Expect
        (Problem ("{""type"": ""integer""}", Make_Integer (3)), "",
         "an integer");
      Expect
        (Problem ("{""type"": ""any""}", Null_Value), "", "any takes null");
   end Type_Is_Checked;

   procedure An_Integer_Is_Not_A_String (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Problem ("{""type"": ""string""}", Make_Integer (5)),
         "input.x: expected string", "an integer");
   end An_Integer_Is_Not_A_String;

   procedure Const_Is_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant String := "{""type"": ""string"", ""const"": ""v1""}";
   begin
      Expect (Problem (Rule, Make_String ("v1")), "", "the constant");
      Expect
        (Problem (Rule, Make_String ("v2")), "input.x: expected 'v1'",
         "another value");
   end Const_Is_Checked;

   procedure Min_Length_Counts_Characters (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant String :=
        "{""type"": ""string"", ""min_length"": 3}";
      --  Three characters in six bytes: e with an acute accent, three times.
      Accented : constant String :=
        [for I in 1 .. 6
         => Character'Val (if I mod 2 = 1 then 16#C3# else 16#A9#)];
   begin
      Expect (Problem (Rule, Make_String (Accented)), "", "three characters");
      Expect
        (Problem (Rule, Make_String (Accented (1 .. 4))),
         "input.x: must be at least 3 characters", "two characters");
   end Min_Length_Counts_Characters;

   procedure Pattern_Is_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant String :=
        "{""type"": ""string"", ""pattern"": ""^[a-z]+-[0-9]+$""}";
   begin
      Expect (Problem (Rule, Make_String ("synapse-82")), "", "a match");
      Expect
        (Problem (Rule, Make_String ("Synapse 82")),
         "input.x: does not match required pattern", "no match");
   end Pattern_Is_Checked;

   procedure Enum_Is_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant String :=
        "{""type"": ""string"", ""enum"": [""TODO"", ""DONE""]}";
   begin
      Expect (Problem (Rule, Make_String ("DONE")), "", "a listed value");
      Expect
        (Problem (Rule, Make_String ("LATER")),
         "input.x: value 'LATER' is not allowed", "an unlisted value");
   end Enum_Is_Checked;

   procedure Timestamp_Is_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant String := "{""type"": ""timestamp""}";
   begin
      Expect
        (Problem (Rule, Make_String ("2026-11-27T16:26:26+01:00")), "",
         "an offset");
      Expect
        (Problem (Rule, Make_String ("2026-11-27T16:26:26Z")), "", "a Z");
      Expect
        (Problem (Rule, Make_String ("27.11.2026")),
         "input.x: expected RFC3339, YYYY-MM-DDTHH:MM:SS then Z or a" &
         " colon-separated numeric offset",
         "another form");
   end Timestamp_Is_Checked;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Field_Rules");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, Type_Is_Checked'Access, "Type is checked");
      Register_Routine
        (T, An_Integer_Is_Not_A_String'Access, "An integer is not a string");
      Register_Routine (T, Const_Is_Checked'Access, "Const is checked");
      Register_Routine
        (T, Min_Length_Counts_Characters'Access,
         "Min_length counts characters, not bytes");
      Register_Routine (T, Pattern_Is_Checked'Access, "Pattern is checked");
      Register_Routine (T, Enum_Is_Checked'Access, "Enum is checked");
      Register_Routine
        (T, Timestamp_Is_Checked'Access, "Timestamp is checked");
   end Register_Tests;

end Synapse.Core.Field_Rules.Tests;
