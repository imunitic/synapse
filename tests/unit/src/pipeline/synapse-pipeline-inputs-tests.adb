with Ada.Containers;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

package body Synapse.Pipeline.Inputs.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type JSON.Value;
   use type JSON.Kind;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Parsed (Text : String) return JSON.Value is
     (JSON.Parse (Text).Item);

   --  The design's example: one required string and one optional string.
   Brief : constant String :=
     "{""task_id"": ""synapse-070"", ""instructions"": ""Be brief.""}";

   Task_Input : constant String :=
     "{""fields"": {"
     & """task_id"": {""type"": ""string"", ""required"": true,"
     & " ""pattern"": ""^[a-z]+-[0-9]+$"","
     & " ""description"": ""The task note's id.""},"
     & """instructions"": {""type"": ""string"","
     & " ""description"": ""Extra requirements.""}}}";

   Two_Required : constant String :=
     "{""fields"": {"
     & """task_id"": {""type"": ""string"", ""required"": true,"
     & " ""description"": ""The task note's id.""},"
     & """branch"": {""type"": ""string"", ""required"": true,"
     & " ""description"": ""The branch to work on.""}}}";

   function Problem_List (Result : Acceptance) return String is
      Text : Unbounded_String;
   begin
      for P of Result.Problems loop
         Append (Text, P & ASCII.LF);
      end loop;
      return To_String (Text);
   end Problem_List;

   procedure No_Declaration_Passes_Any_Input_Through
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Given  : constant JSON.Value := Parsed ("{""anything"": [1, """"]}");
      Result : constant Acceptance := Accept_Input (JSON.Null_Value, Given);
      Text   : constant Acceptance :=
        Accept_Input (JSON.Null_Value, Parsed ("""a sentence"""));
      None   : constant Acceptance :=
        Accept_Input (JSON.Null_Value, JSON.Null_Value);
   begin
      Assert
        (Result.Accepted and then Result.Input = Given, "an object as is");
      Assert
        (Text.Accepted and then Text.Input = Parsed ("""a sentence"""),
         "a string as is");
      Assert
        (None.Accepted and then JSON.Kind_Of (None.Input) = JSON.JSON_Null,
         "null as is");
      Assert
        (not Single_Text_Field (JSON.Null_Value).Found,
         "no text field without a declaration");
   end No_Declaration_Passes_Any_Input_Through;

   procedure A_String_Becomes_The_One_Required_String_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Declared : constant JSON.Value := Parsed (Task_Input);
      Result   : constant Acceptance :=
        Accept_Input (Declared, Parsed ("""synapse-070"""));
   begin
      Assert
        (Single_Text_Field (Declared).Found
         and then To_String (Single_Text_Field (Declared).Value) = "task_id",
         "task_id is the one required string field");
      Assert
        (Result.Accepted
         and then Result.Input = Parsed ("{""task_id"": ""synapse-070""}"),
         "the string fills task_id");
   end A_String_Becomes_The_One_Required_String_Field;

   procedure A_String_Is_Refused_With_Two_Required_Fields
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Declared : constant JSON.Value := Parsed (Two_Required);
      Result   : constant Acceptance :=
        Accept_Input (Declared, Parsed ("""synapse-070"""));
   begin
      Assert
        (not Single_Text_Field (Declared).Found,
         "no single text field with two required fields");
      Assert (not Result.Accepted, "the string is refused");
      Assert
        (Problem_List (Result) = "input: expected a JSON object" & ASCII.LF,
         "as not an object: " & Problem_List (Result));
   end A_String_Is_Refused_With_Two_Required_Fields;

   procedure Every_Problem_Is_Returned (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Acceptance :=
        Accept_Input
          (Parsed (Task_Input),
           Parsed ("{""task_id"": ""Not An Id"", ""extra"": 1}"));
   begin
      Assert (not Result.Accepted, "refused");
      Assert
        (Result.Problems.Length = 2,
         "two problems: " & Problem_List (Result));
      Assert
        (Problem_List (Result) =
           "input.task_id: does not match required pattern" & ASCII.LF
           & "input.extra: unknown field" & ASCII.LF,
         "both, in order: " & Problem_List (Result));
   end Every_Problem_Is_Returned;

   procedure An_Empty_Optional_Field_Is_Dropped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Result : constant Acceptance :=
        Accept_Input
          (Parsed (Task_Input),
           Parsed ("{""task_id"": ""synapse-070"", ""instructions"": """"}"));
      Kept   : constant Acceptance :=
        Accept_Input (Parsed (Task_Input), Parsed (Brief));
   begin
      Assert
        (Result.Accepted
         and then Result.Input = Parsed ("{""task_id"": ""synapse-070""}"),
         "instructions given as """" is dropped");
      Assert
        (Kept.Accepted
         and then Kept.Input = Parsed (Brief),
         "a given optional field is kept");
   end An_Empty_Optional_Field_Is_Dropped;

   procedure A_Null_Input_With_A_Required_Field_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Result : constant Acceptance :=
        Accept_Input (Parsed (Task_Input), JSON.Null_Value);
   begin
      Assert (not Result.Accepted, "refused");
      Assert
        (Problem_List (Result) =
           "input.task_id: required field is missing" & ASCII.LF,
         "checked as {}: " & Problem_List (Result));
   end A_Null_Input_With_A_Required_Field_Is_Refused;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Inputs");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, No_Declaration_Passes_Any_Input_Through'Access,
         "No declaration passes any input through");
      Register_Routine
        (T, A_String_Becomes_The_One_Required_String_Field'Access,
         "A string becomes the one required string field");
      Register_Routine
        (T, A_String_Is_Refused_With_Two_Required_Fields'Access,
         "A string is refused when there are two required fields");
      Register_Routine
        (T, Every_Problem_Is_Returned'Access, "Every problem is returned");
      Register_Routine
        (T, An_Empty_Optional_Field_Is_Dropped'Access,
         "An empty optional field is dropped");
      Register_Routine
        (T, A_Null_Input_With_A_Required_Field_Is_Refused'Access,
         "A null input with a required field is refused");
   end Register_Tests;

end Synapse.Pipeline.Inputs.Tests;
