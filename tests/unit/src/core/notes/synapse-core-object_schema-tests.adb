with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with Synapse.Core.Text_Lists;

package body Synapse.Core.Object_Schema.Tests is

   use AUnit.Assertions;
   use JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Json_Of (Text : String) return Value is
      R : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (R.Ok, "the JSON parses: " & Text);
      return R.Item;
   end Json_Of;

   --  The problems joined with " | ", or "" when there are none.
   function Joined (List : Text_Lists.Vector) return String is
      use Ada.Strings.Unbounded;
      Result : Unbounded_String;
   begin
      for Problem of List loop
         if Length (Result) > 0 then
            Append (Result, " | ");
         end if;
         Append (Result, Problem);
      end loop;
      return To_String (Result);
   end Joined;

   function Declaration_Problems (Text : String) return String is
     (Joined (Validate_Declaration (Json_Of (Text))));

   procedure Expect (Got, Wanted, What : String) is
   begin
      Assert (Got = Wanted, What & ": got """ & Got & """");
   end Expect;

   --  One field `x` with Rule_Members added to a string rule with a
   --  description.
   function One_Field (Rule_Members : String) return String is
     ("{""fields"": {""x"": {""type"": ""string"", ""description"": ""d""" &
      Rule_Members & "}}}");

   ---------------------------------------------------------------------------
   --  The declaration
   ---------------------------------------------------------------------------

   Declared_Text : constant String :=
     "{""fields"": {" &
     """task_id"": {""type"": ""string"", ""required"": true," &
     " ""pattern"": ""^[a-z]+-[0-9]+$"", ""description"": ""The task.""}," &
     """instructions"": {""type"": ""string"", ""description"": ""Extra.""}," &
     """mode"": {""type"": ""string"", ""enum"": [""fast"", ""slow""]," &
     " ""description"": ""How.""}," &
     """count"": {""type"": ""integer"", ""description"": ""How many.""}," &
     """tags"": {""type"": ""list"", ""items"": ""string""," &
     " ""description"": ""Tags.""}," &
     """files"": {""type"": ""list"", ""description"": ""Files.""," &
     " ""items"": {""fields"": {" &
     """path"": {""type"": ""string"", ""required"": true," &
     " ""description"": ""A path.""}," &
     """lines"": {""type"": ""list"", ""description"": ""Ranges.""," &
     " ""items"": {""fields"": {""from"": {""type"": ""integer""," &
     " ""required"": true, ""description"": ""First line.""}}}}}}}}," &
     """checks"": [{""!="": [{""var"": ""task_id""}, ""abc-1""]," &
     " ""message"": ""abc-1 is reserved""}]}";

   procedure Fields_And_Checks_Are_Valid (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect (Declaration_Problems (Declared_Text), "", "the declaration");
   end Fields_And_Checks_Are_Valid;

   procedure Description_Is_Required (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Declaration_Problems
           ("{""fields"": {""task_id"": {""type"": ""string""}}}"),
         "input.fields.task_id.description: required string is missing",
         "no description");
      Expect
        (Declaration_Problems
           ("{""fields"": {""task_id"": {""type"": ""string""," &
            " ""description"": 3}}}"),
         "input.fields.task_id.description: required string is missing",
         "a description that is not a string");
   end Description_Is_Required;

   procedure Note_Rules_Are_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Declaration_Problems
           ("{""fields"": {""x"": {""type"": ""any""," &
            " ""description"": ""d""," &
            " ""mutable"": false, ""format"": ""rfc3339""," &
            " ""timezone"": ""local"", ""update_on"": ""write""}}}"),
         "input.fields.x.mutable: not allowed in an input" &
         " | input.fields.x.format: not allowed in an input" &
         " | input.fields.x.timezone: not allowed in an input" &
         " | input.fields.x.update_on: not allowed in an input" &
         " | input.fields.x.type: any is not allowed in an input",
         "the rules about a note's life and the type any");
   end Note_Rules_Are_Refused;

   procedure Unknown_Key_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Declaration_Problems
           ("{""fields"": {""x"": {""type"": ""string""," &
            " ""description"": ""d""}}, ""lints"": []}"),
         "input.lints: unsupported key", "a top-level key");
      Expect
        (Declaration_Problems (One_Field (", ""default"": ""a""")),
         "input.fields.x.default: unsupported key", "a field key");
      Expect
        (Declaration_Problems
           ("{""fields"": {""x"": {""type"": ""text""," &
            " ""description"": ""d""}}}"),
         "input.fields.x.type: unsupported type 'text'", "a type");
   end Unknown_Key_Is_Refused;

   procedure Bad_Field_Name_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Declaration_Problems
           ("{""fields"": {""Task-Id"": {""type"": ""string""," &
            " ""description"": ""d""}}}"),
         "input.fields.Task-Id: a field name must match ^[a-z][a-z0-9_]*$",
         "a capital and a dash");
      Expect
        (Declaration_Problems ("{""fields"": {}}"),
         "input.fields: must declare at least one field", "no field");
      Expect
        (Declaration_Problems ("{""checks"": []}"),
         "input.fields: required mapping is missing", "no fields");
   end Bad_Field_Name_Is_Refused;

   procedure Items_Fields_Are_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Declaration_Problems
           ("{""fields"": {""files"": {""type"": ""list""," &
            " ""description"": ""d"", ""items"": {""fields"": {" &
            """path"": {""type"": ""any""}}, ""extra"": 1}}}}"),
         "input.fields.files.items.extra: unsupported key" &
         " | input.fields.files.items.fields.path.description:" &
         " required string is missing" &
         " | input.fields.files.items.fields.path.type:" &
         " any is not allowed in an input",
         "a nested field and a stray key");
      Expect
        (Declaration_Problems
           ("{""fields"": {""files"": {""type"": ""list""," &
            " ""description"": ""d""}}}"),
         "input.fields.files.items: required for a list", "no items");
      Expect
        (Declaration_Problems
           ("{""fields"": {""files"": {""type"": ""list""," &
            " ""description"": ""d"", ""items"": ""list""}}}"),
         "input.fields.files.items: unsupported type 'list', expected one" &
         " of string integer boolean timestamp or fields",
         "a list of lists");
   end Items_Fields_Are_Checked;

   procedure Bad_Pattern_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Declaration_Problems (One_Field (", ""pattern"": ""[a""")),
         "input.fields.x.pattern: UnterminatedClass", "an open class");
   end Bad_Pattern_Is_Refused;

   procedure Unknown_Operator_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Declaration_Problems
           ("{""fields"": {""x"": {""type"": ""string""," &
            " ""description"": ""d""}}," &
            " ""checks"": [{""==="": [1, 1]}, {""frob"": [1]}]}"),
         "input.checks[1]: unknown operator '==='" &
         " | input.checks[2]: unknown operator 'frob'",
         "two operators");
   end Unknown_Operator_Is_Refused;

   procedure Every_Declaration_Problem (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Declaration_Problems
           ("{""fields"": {""a"": {""type"": ""string""}," &
            " ""b"": {""description"": ""d"", ""required"": ""yes""}}}"),
         "input.fields.a.description: required string is missing" &
         " | input.fields.b.required: must be boolean" &
         " | input.fields.b.type: required string is missing",
         "problems in two fields");
   end Every_Declaration_Problem;

   ---------------------------------------------------------------------------
   --  The object
   ---------------------------------------------------------------------------

   function Object_Problems (Given : String) return String is
     (Joined (Validate_Object (Json_Of (Declared_Text), Json_Of (Given))));

   procedure Not_An_Object (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems ("""abc-2"""), "input: expected a JSON object",
         "a string");
      Expect
        (Object_Problems ("[]"), "input: expected a JSON object", "an array");
   end Not_An_Object;

   procedure Unknown_Field (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems ("{""task_id"": ""abc-2"", ""task"": ""x""}"),
         "input.task: unknown field", "a field not declared");
   end Unknown_Field;

   procedure Missing_Required (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems ("{}"), "input.task_id: required field is missing",
         "nothing given");
      Expect
        (Object_Problems ("{""task_id"": ""abc-2""}"), "",
         "the required field alone");
   end Missing_Required;

   procedure Empty_Optional_Is_Not_Given (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems
           ("{""task_id"": ""abc-2"", ""mode"": """", ""tags"": []}"),
         "", "an empty string outside the enum and an empty list");
      Expect
        (Object_Problems ("{""task_id"": """"}"),
         "input.task_id: does not match required pattern",
         "an empty required field is checked");
   end Empty_Optional_Is_Not_Given;

   procedure Wrong_Type (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems ("{""task_id"": ""abc-2"", ""count"": ""3""}"),
         "input.count: expected integer", "a string for an integer");
      Expect
        (Object_Problems ("{""task_id"": 7}"),
         "input.task_id: expected string",
         "an integer for a string");
   end Wrong_Type;

   procedure Pattern_Is_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems ("{""task_id"": ""ABC 2""}"),
         "input.task_id: does not match required pattern", "a bad id");
   end Pattern_Is_Checked;

   procedure Enum_Is_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems ("{""task_id"": ""abc-2"", ""mode"": ""slow""}"), "",
         "a listed value");
      Expect
        (Object_Problems ("{""task_id"": ""abc-2"", ""mode"": ""medium""}"),
         "input.mode: value 'medium' is not allowed", "an unlisted value");
   end Enum_Is_Checked;

   procedure List_Of_Strings (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems
           ("{""task_id"": ""abc-2"", ""tags"": [""a"", ""b""]}"),
         "", "two strings");
      Expect
        (Object_Problems
           ("{""task_id"": ""abc-2"", ""tags"": [""a"", 2, true]}"),
         "input.tags[2]: expected string | input.tags[3]: expected string",
         "items that are not strings");
      Expect
        (Object_Problems ("{""task_id"": ""abc-2"", ""tags"": ""a""}"),
         "input.tags: expected list", "a string for a list");
   end List_Of_Strings;

   procedure Nested_Items_With_Fields (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems
           ("{""task_id"": ""abc-2"", ""files"": [{""path"": ""a""," &
            " ""lines"": [{""from"": 1}]}]}"),
         "", "a valid list of files");
      Expect
        (Object_Problems
           ("{""task_id"": ""abc-2"", ""files"": [{""path"": ""a""}," &
            " {""lines"": [{""from"": 1}, {""from"": ""x""}, {}]," &
            " ""size"": 3}, ""c""]}"),
         "input.files[2].path: required field is missing" &
         " | input.files[2].lines[2].from: expected integer" &
         " | input.files[2].lines[3].from: required field is missing" &
         " | input.files[2].size: unknown field" &
         " | input.files[3]: expected a JSON object",
         "problems two levels deep");
   end Nested_Items_With_Fields;

   procedure Failing_Check_Gives_Message (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Without_Message : constant Value :=
        Json_Of
          ("{""fields"": {""a"": {""type"": ""string""," &
           " ""description"": ""d""}}," &
           " ""checks"": [{""eq"": [{""var"": ""a""}, ""x""]}]}");
      Got : constant String :=
        Joined (Validate_Object (Without_Message, Json_Of ("{""a"": ""y""}")));
   begin
      Expect
        (Object_Problems ("{""task_id"": ""abc-1""}"), "abc-1 is reserved",
         "a check with a message");
      Assert
        (Ada.Strings.Fixed.Index (Got, "rule failed: {""==""") = 1,
         "a check without a message gives its rule: got """ & Got & """");
      Expect
        (Joined
           (Validate_Object (Without_Message, Json_Of ("{""a"": ""x""}"))),
         "", "the check holds");
   end Failing_Check_Gives_Message;

   procedure Checks_Wait_For_Fields (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Object_Problems ("{""task_id"": ""abc-1"", ""count"": ""x""}"),
         "input.count: expected integer", "a field is wrong");
   end Checks_Wait_For_Fields;

   procedure Object_Under_Root (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Declared : constant Value :=
        Json_Of
          ("{""fields"": {""item"": {""type"": ""string""," &
           " ""required"": true, ""description"": ""The item.""}}}");
   begin
      Expect
        (Joined (Validate_Object (Declared, Json_Of ("{}"), Root => "data")),
         "data.item: required field is missing",
         "a missing field under data");
   end Object_Under_Root;

   procedure List_Item_Under_Root (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Declared : constant Value :=
        Json_Of
          ("{""fields"": {""problems"": {""type"": ""list""," &
           " ""description"": ""What is wrong."", ""items"": {""fields"":" &
           " {""issue"": {""type"": ""string"", ""required"": true," &
           " ""description"": ""The issue.""}}}}}}");
   begin
      Expect
        (Joined
           (Validate_Object
              (Declared,
               Json_Of ("{""problems"": [{""issue"": ""a""}, {}]}"),
               Root => "data")),
         "data.problems[2].issue: required field is missing",
         "a list item under data");
   end List_Item_Under_Root;

   procedure Declaration_Under_Root (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        (Joined
           (Validate_Declaration
              (Json_Of ("{""fields"": {""x"": {""type"": ""string""}}}"),
               Root => "Data")),
         "Data.fields.x.description: required string is missing",
         "a declaration under Data");
   end Declaration_Under_Root;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Object_Schema");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Fields_And_Checks_Are_Valid'Access,
         "A declaration with fields and checks is valid");
      Register_Routine
        (T, Description_Is_Required'Access, "Description is required");
      Register_Routine
        (T, Note_Rules_Are_Refused'Access,
         "Mutable, format, timezone, update_on and any are refused");
      Register_Routine
        (T, Unknown_Key_Is_Refused'Access, "An unknown key is refused");
      Register_Routine
        (T, Bad_Field_Name_Is_Refused'Access, "A bad field name is refused");
      Register_Routine
        (T, Items_Fields_Are_Checked'Access,
         "Items as fields is checked recursively");
      Register_Routine
        (T, Bad_Pattern_Is_Refused'Access, "A bad pattern is refused");
      Register_Routine
        (T, Unknown_Operator_Is_Refused'Access,
         "A check with an unknown operator is refused");
      Register_Routine
        (T, Every_Declaration_Problem'Access,
         "Every problem is reported, not only the first");
      Register_Routine (T, Not_An_Object'Access, "Not an object");
      Register_Routine (T, Unknown_Field'Access, "Unknown field");
      Register_Routine (T, Missing_Required'Access, "Missing required");
      Register_Routine
        (T, Empty_Optional_Is_Not_Given'Access,
         "Empty optional counts as not given");
      Register_Routine (T, Wrong_Type'Access, "Wrong type");
      Register_Routine (T, Pattern_Is_Checked'Access, "Pattern");
      Register_Routine (T, Enum_Is_Checked'Access, "Enum");
      Register_Routine (T, List_Of_Strings'Access, "A list of strings");
      Register_Routine
        (T, Nested_Items_With_Fields'Access,
         "A list of items with fields, two levels deep, with indexed paths");
      Register_Routine
        (T, Failing_Check_Gives_Message'Access,
         "A failing check gives its message");
      Register_Routine
        (T, Checks_Wait_For_Fields'Access,
         "Checks do not run while a field is wrong");
      Register_Routine
        (T, Object_Under_Root'Access,
         "Validate_Object names paths under the given root");
      Register_Routine
        (T, List_Item_Under_Root'Access,
         "A list item field is named under the root");
      Register_Routine
        (T, Declaration_Under_Root'Access,
         "Validate_Declaration names paths under the given root");
   end Register_Tests;

end Synapse.Core.Object_Schema.Tests;
