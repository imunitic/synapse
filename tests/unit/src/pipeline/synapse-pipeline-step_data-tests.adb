with Ada.Containers;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Text_Lists;

package body Synapse.Pipeline.Step_Data.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type JSON.Value;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Parsed (Text : String) return JSON.Value is
      Result : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Result.Ok, "the sample is JSON: " & Text);
      return Result.Item;
   end Parsed;

   --  A result that ends with Outcome and holds Data.
   function Result (Outcome, Data : String) return JSON.Value is
     (Parsed
        ("{""outcome"": """ & Outcome & """, ""summary"": ""s"", ""data"": "
         & Data & "}"));

   Task_Note_Data : constant String :=
     "{""fields"": {""task_note"": {""type"": ""string"", "
     & """required"": true, ""description"": ""The task note.""}}}";

   --  A step that declares Data and Outcomes as given; "" for none.
   function Step_With (Data, Outcomes : String := "") return Resolved.Step is
      Item : Resolved.Step;
   begin
      if Data'Length > 0 then
         Item.Data := Parsed (Data);
      end if;
      if Outcomes'Length > 0 then
         Item.Outcomes := Parsed (Outcomes);
      end if;
      return Item;
   end Step_With;

   Item_Data : constant String :=
     "{""fields"": {""item"": {""type"": ""string"", ""required"": true, "
     & """description"": ""The item.""}}}";

   Step_Outcomes : constant String :=
     "{""Done"": ""All done."", ""Blocked"": {""description"": ""Stuck."", "
     & """data"": {""blocker"": {""type"": ""string"", ""required"": true, "
     & """description"": ""Why.""}}}}";

   function Image (List : Synapse.Core.Text_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Line of List loop
         Append (Text, Line & "|");
      end loop;
      return To_String (Text);
   end Image;

   function Holds (List : Synapse.Core.Text_Lists.Vector; Line : String)
      return Boolean is
     (for some Item of List => To_String (Item) = Line);

   procedure Problems_Is_Empty_Without_Data (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Problems_Found : constant Synapse.Core.Text_Lists.Vector :=
        Problems
          (Step_With (Outcomes => "{""Done"": ""All done.""}"),
           Result ("Done", "{""anything"": 1}"));
   begin
      Assert (Problems_Found.Is_Empty, "found: " & Image (Problems_Found));
      Assert
        (Declaration_For (Step_With, "Done") = JSON.Null_Value,
         "no declaration");
   end Problems_Is_Empty_Without_Data;

   procedure A_Missing_Required_Field_Is_Named_Under_Data
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Found : constant Synapse.Core.Text_Lists.Vector :=
        Problems (Step_With (Item_Data), Result ("Done", "{}"));
   begin
      Assert
        (Holds (Found, "data.item: required field is missing"),
         "found: " & Image (Found));
   end A_Missing_Required_Field_Is_Named_Under_Data;

   procedure An_Undeclared_Field_Is_A_Problem (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Found : constant Synapse.Core.Text_Lists.Vector :=
        Problems
          (Step_With (Item_Data),
           Result ("Done", "{""item"": ""x"", ""extra"": 1}"));
   begin
      Assert (Found.Length = 1, "one problem: " & Image (Found));
      Assert
        (Index (Found.First_Element, "data.extra") > 0,
         "names data.extra: " & Image (Found));
   end An_Undeclared_Field_Is_A_Problem;

   procedure An_Outcome_Field_Is_Required_Only_With_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Item : constant Resolved.Step := Step_With (Item_Data, Step_Outcomes);
      Blocked : constant Synapse.Core.Text_Lists.Vector :=
        Problems (Item, Result ("Blocked", "{""item"": ""x""}"));
      Done : constant Synapse.Core.Text_Lists.Vector :=
        Problems (Item, Result ("Done", "{""item"": ""x""}"));
      Only_Outcome : constant Synapse.Core.Text_Lists.Vector :=
        Problems
          (Step_With (Outcomes => Step_Outcomes),
           Result ("Done", "{""anything"": 1}"));
   begin
      Assert
        (Holds (Blocked, "data.blocker: required field is missing"),
         "with Blocked: " & Image (Blocked));
      Assert (Done.Is_Empty, "with Done: " & Image (Done));
      Assert
        (Only_Outcome.Is_Empty,
         "an outcome without data on a step without Data: "
         & Image (Only_Outcome));
   end An_Outcome_Field_Is_Required_Only_With_It;

   --  The step declares task_note, and only the previous step's result
   --  holds it: Problems sees only the step's own result, so the field is
   --  missing.
   procedure A_Steps_Data_Is_Not_Filled_From_The_Previous_Steps_Data
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Item  : constant Resolved.Step := Step_With (Task_Note_Data);
      Found : constant Synapse.Core.Text_Lists.Vector :=
        Problems (Item, Result ("Done", "{}"));
   begin
      Assert
        (Holds (Found, "data.task_note: required field is missing"),
         "found: " & Image (Found));
      Assert
        (Problems (Item, Result ("Done", "{""task_note"": ""t""}")).Is_Empty,
         "the step sets it itself");
   end A_Steps_Data_Is_Not_Filled_From_The_Previous_Steps_Data;

   procedure Data_That_Is_Not_An_Object_Is_A_Problem
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Found : constant Synapse.Core.Text_Lists.Vector :=
        Problems (Step_With (Item_Data), Result ("Done", "[]"));
   begin
      Assert
        (Found.Length = 1
           and then To_String (Found.First_Element) =
                    "data: expected an object",
         "found: " & Image (Found));
   end Data_That_Is_Not_An_Object_Is_A_Problem;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Step_Data");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Problems_Is_Empty_Without_Data'Access,
         "Problems is empty for a step without Data");
      Register_Routine
        (T, A_Missing_Required_Field_Is_Named_Under_Data'Access,
         "A missing required field is a problem named under data");
      Register_Routine
        (T, An_Undeclared_Field_Is_A_Problem'Access,
         "An undeclared field is a problem");
      Register_Routine
        (T, An_Outcome_Field_Is_Required_Only_With_It'Access,
         "An outcome's data field is required only with that outcome");
      Register_Routine
        (T, A_Steps_Data_Is_Not_Filled_From_The_Previous_Steps_Data'Access,
         "A step's data is not filled from the previous step's data");
      Register_Routine
        (T, Data_That_Is_Not_An_Object_Is_A_Problem'Access,
         "data that is not an object is a problem");
   end Register_Tests;

end Synapse.Pipeline.Step_Data.Tests;
