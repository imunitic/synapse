with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Text_Lists;

package body Synapse.Pipeline.Data_Shapes.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Parse (Text : String) return JSON.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Parsed.Ok, "the sample is JSON: " & Text);
      return Parsed.Item;
   end Parse;

   Task_Note : constant String :=
     """task_note"": {""type"": ""string"", ""required"": true}";
   Remaining : constant String := """remaining"": {""type"": ""integer""}";

   function Shapes return JSON.Value is
     (Parse ("{""fields"": {" & Task_Note & ", " & Remaining & "}}"));

   --  The lines of List, joined by " | ", to compare in one assertion.
   function Joined (List : Synapse.Core.Text_Lists.Vector) return String is
      Result : Unbounded_String;
   begin
      for Line of List loop
         if Length (Result) > 0 then
            Append (Result, " | ");
         end if;
         Append (Result, Line);
      end loop;
      return To_String (Result);
   end Joined;

   procedure Assert_Same (Got, Expected : JSON.Value; Label : String) is
   begin
      Assert
        (JSON."=" (Got, Expected) and then
         JSON.To_String (Got) = JSON.To_String (Expected),
         Label & ": got " & JSON.To_String (Got) & ", expected "
         & JSON.To_String (Expected));
   end Assert_Same;

   procedure A_List_Is_The_Named_Form (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Named (Parse ("[""task_note""]")), "a list");
      Assert (Is_Named (Parse ("[]")), "an empty list");
      Assert (not Is_Named (Parse ("{""fields"": {}}")), "an object");
      Assert (not Is_Named (JSON.Null_Value), "null");
   end A_List_Is_The_Named_Form;

   procedure Names_Of_Gives_The_Names_In_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Joined (Names_Of (Parse ("[""remaining"", ""task_note""]")))
         = "remaining | task_note",
         "in order");
      Assert
        (Names_Of (Parse ("{""fields"": {}}"))
         .Is_Empty, "an object has none");
   end Names_Of_Gives_The_Names_In_Order;

   procedure An_Empty_List_Is_A_Problem (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Joined (Name_List_Problems (Parse ("[]"), "Data"))
         = "Data: the list of names is empty",
         "says so");
   end An_Empty_List_Is_A_Problem;

   procedure An_Item_That_Is_Not_A_String_Is_A_Problem
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Problems : constant Synapse.Core.Text_Lists.Vector :=
        Name_List_Problems (Parse ("[""task_note"", 3, """"]"), "Data");
   begin
      Assert
        (Joined (Problems)
         = "Data: item 2 is not a name | Data: item 3 is not a name",
         "a number and an empty string: " & Joined (Problems));
   end An_Item_That_Is_Not_A_String_Is_A_Problem;

   procedure A_Name_Given_Twice_Is_A_Problem (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Problems : constant Synapse.Core.Text_Lists.Vector :=
        Name_List_Problems
          (Parse ("[""task_note"", ""remaining"", ""task_note""]"),
           "Outcomes.Done.data");
   begin
      Assert
        (Joined (Problems) = "Outcomes.Done.data: 'task_note' is named twice",
         "names it: " & Joined (Problems));
      Assert
        (Name_List_Problems (Parse ("[""task_note""]"), "Data").Is_Empty,
         "a good list has none");
   end A_Name_Given_Twice_Is_A_Problem;

   procedure Named_Fields_Takes_The_Lists_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Same
        (Named_Fields (Shapes, Parse ("[""remaining"", ""task_note""]")),
         Parse ("{" & Remaining & ", " & Task_Note & "}"),
         "each declaration, in the list's order");
   end Named_Fields_Takes_The_Lists_Order;

   procedure Named_Fields_Skips_An_Undeclared_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Same
        (Named_Fields (Shapes, Parse ("[""findings"", ""task_note""]")),
         Parse ("{" & Task_Note & "}"),
         "only the declared name");
   end Named_Fields_Skips_An_Undeclared_Name;

   procedure Resolve_Data_Replaces_Names (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert_Same
        (Resolve_Data (Shapes, Parse ("[""task_note""]")),
         Parse ("{""fields"": {" & Task_Note & "}}"),
         "the declared fields");
   end Resolve_Data_Replaces_Names;

   procedure Resolve_Data_Leaves_Inline_Data (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Inline : constant JSON.Value :=
        Parse ("{""fields"": {""x"": {""type"": ""string""}}, "
               & """checks"": []}");
   begin
      Assert_Same (Resolve_Data (Shapes, Inline), Inline, "inline");
      Assert_Same
        (Resolve_Data (Shapes, JSON.Null_Value), JSON.Null_Value, "null");
   end Resolve_Data_Leaves_Inline_Data;

   procedure Resolve_Outcomes_Replaces_Named_Data
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Same
        (Resolve_Outcomes
           (Shapes,
            Parse ("{""Done"": {""description"": ""all done"", "
                   & """data"": [""remaining""]}}")),
         Parse ("{""Done"": {""description"": ""all done"", "
                & """data"": {" & Remaining & "}}}"),
         "the declared fields");
   end Resolve_Outcomes_Replaces_Named_Data;

   procedure Resolve_Outcomes_Leaves_Strings_And_Inline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Outcomes : constant JSON.Value :=
        Parse ("{""Done"": ""all done"", ""Blocked"": {""description"": "
               & """stuck"", ""data"": {""why"": {""type"": ""string""}}}}");
   begin
      Assert_Same
        (Resolve_Outcomes (Shapes, Outcomes), Outcomes, "unchanged");
      Assert_Same
        (Resolve_Outcomes (Shapes, JSON.Null_Value), JSON.Null_Value,
         "null");
   end Resolve_Outcomes_Leaves_Strings_And_Inline;

   procedure Undeclared_Names_What_Is_Not_Declared
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Joined
           (Undeclared
              (Shapes,
               Parse ("[""findings"", ""task_note"", ""problems""]")))
         = "findings | problems",
         "the two undeclared");
      Assert
        (Undeclared (Shapes, Parse ("[""task_note""]")).Is_Empty,
         "none when all are declared");
   end Undeclared_Names_What_Is_Not_Declared;

   procedure With_Null_Shapes_Every_Name_Is_Undeclared
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Joined
           (Undeclared
              (JSON.Null_Value, Parse ("[""task_note"", ""remaining""]")))
         = "task_note | remaining",
         "every name");
      Assert
        (not Declares (JSON.Null_Value, "task_note"), "declares nothing");
   end With_Null_Shapes_Every_Name_Is_Undeclared;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Data_Shapes");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_List_Is_The_Named_Form'Access,
         "A list is the named form and an object is not");
      Register_Routine
        (T, Names_Of_Gives_The_Names_In_Order'Access,
         "Names_Of gives the names in order");
      Register_Routine
        (T, An_Empty_List_Is_A_Problem'Access,
         "An empty list of names is a problem");
      Register_Routine
        (T, An_Item_That_Is_Not_A_String_Is_A_Problem'Access,
         "A list item that is not a string is a problem");
      Register_Routine
        (T, A_Name_Given_Twice_Is_A_Problem'Access,
         "A name given twice is a problem");
      Register_Routine
        (T, Named_Fields_Takes_The_Lists_Order'Access,
         "Named_Fields takes each declaration in the list's order");
      Register_Routine
        (T, Named_Fields_Skips_An_Undeclared_Name'Access,
         "Named_Fields skips an undeclared name");
      Register_Routine
        (T, Resolve_Data_Replaces_Names'Access,
         "Resolve_Data replaces names by their declarations");
      Register_Routine
        (T, Resolve_Data_Leaves_Inline_Data'Access,
         "Resolve_Data leaves inline Data unchanged");
      Register_Routine
        (T, Resolve_Outcomes_Replaces_Named_Data'Access,
         "Resolve_Outcomes replaces an outcome's named data");
      Register_Routine
        (T, Resolve_Outcomes_Leaves_Strings_And_Inline'Access,
         "Resolve_Outcomes leaves string outcomes and inline data unchanged");
      Register_Routine
        (T, Undeclared_Names_What_Is_Not_Declared'Access,
         "Undeclared names what the pipeline does not declare");
      Register_Routine
        (T, With_Null_Shapes_Every_Name_Is_Undeclared'Access,
         "With null Shapes every name is undeclared");
   end Register_Tests;

end Synapse.Pipeline.Data_Shapes.Tests;
