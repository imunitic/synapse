with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Optional_Text;

package body Synapse.Pipeline.Outcomes.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Parsed (Text : String) return JSON.Value is
     (JSON.Parse (Text).Item);

   procedure A_Word_Is_Written_Like_A_Name (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Is_Word ("Done") and then Is_Word ("Changes_Requested")
         and then Is_Word ("r2") and then Is_Word ("done"),
         "letters, digits and underscores");
      Assert
        (not Is_Word ("") and then not Is_Word ("2fast")
         and then not Is_Word ("_x") and then not Is_Word ("Do ne")
         and then not Is_Word ("Do-ne") and then not Is_Word ("Fertig!"),
         "not empty, not starting with a digit, no other characters");
      Assert
        (not Is_Word ("End") and then not Is_Word ("Pipeline")
         and then not Is_Word ("System") and then not Is_Word ("Agent"),
         "not a keyword or the end of a run");
   end A_Word_Is_Written_Like_A_Name;

   procedure Declared_Outcomes_Are_Checked_As_A_Whole
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Problem (Parsed ("{""A"": ""one"", ""B"": ""two""}")).Found,
         "a sound set");
      Assert (Problem (Parsed ("[""A""]")).Found, "a list");
      Assert (Problem (Parsed ("{}")).Found, "none at all");
      Assert (Problem (Parsed ("{""A"": 1}")).Found, "a meaning that is not text");
   end Declared_Outcomes_Are_Checked_As_A_Whole;

   procedure A_Result_Is_Held_To_What_Was_Declared
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Two : constant JSON.Value :=
        Parsed ("{""Done"": ""It is done."", ""Blocked"": ""Cannot.""}");
   begin
      Assert (not Violation (Two, "Done").Found, "a declared word");
      Assert
        (Violation (Two, "Approved").Found
         and then To_String (Violation (Two, "Approved").Value) =
                  "the outcome 'Approved' is not one this step declares: "
                  & "Done, Blocked",
         "an undeclared one names the words there are");
      Assert
        (not Violation (JSON.Null_Value, "Anything").Found,
         "any word when none is declared");
      Assert
        (Has_Word (Two, "Blocked") and then not Has_Word (Two, "blocked")
         and then not Has_Word (JSON.Null_Value, "Done"),
         "case counts, and nothing is declared by null");
   end A_Result_Is_Held_To_What_Was_Declared;

   procedure The_Test_Of_An_Outcome_Is_Recognised_Again
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tested_Word (Test_For ("Done")).Found
         and then To_String (Tested_Word (Test_For ("Done")).Value) = "Done",
         "what a bare name stands for gives its word back");
      Assert
        (Tested_Word
           (Parsed ("{""=="": [{""var"": ""outcome""}, ""Fixed""]}")).Found,
         "written out in full");
      Assert
        (not Tested_Word
               (Parsed ("{"">"": [{""var"": ""data.n""}, 0]}")).Found
         and then not Tested_Word
                        (Parsed ("{""=="": [{""var"": ""data.n""}, ""x""]}"))
                        .Found
         and then not Tested_Word
                        (Parsed ("{""=="": [{""var"": ""outcome""}, 3]}"))
                        .Found
         and then not Tested_Word
                        (Parsed ("{""and"": [true, true]}")).Found
         and then not Tested_Word (JSON.Null_Value).Found,
         "any other rule is not a test of the outcome");
   end The_Test_Of_An_Outcome_Is_Recognised_Again;

   procedure An_Outcome_Written_As_An_Object_Is_Accepted
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Problem
               (Parsed
                  ("{""Done"": ""It is done."","
                   & " ""Blocked"": {""description"": ""Cannot."","
                   & " ""data"": {""blocker"": {""type"": ""string"","
                   & " ""required"": true,"
                   & " ""description"": ""Why.""}}},"
                   & " ""Waiting"": {""description"": ""Not yet.""}}"))
               .Found,
         "a string, an object with data, and one without");
   end An_Outcome_Written_As_An_Object_Is_Accepted;

   procedure An_Object_Outcome_Without_A_Description_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Missing : constant Synapse.Core.Optional_Text.Option :=
        Problem (Parsed ("{""Done"": {""data"": {}}}"));
   begin
      Assert
        (Missing.Found
         and then To_String (Missing.Value) =
                  "the description of 'Done' is one line of text",
         "no description");
      Assert
        (Problem (Parsed ("{""Done"": {""description"": """"}}")).Found,
         "an empty description");
      Assert
        (Problem (Parsed ("{""Done"": {""description"": ""a\nb""}}")).Found,
         "a description of two lines");
   end An_Object_Outcome_Without_A_Description_Is_Refused;

   procedure An_Object_Outcome_With_An_Unknown_Key_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Found : constant Synapse.Core.Optional_Text.Option :=
        Problem
          (Parsed ("{""Done"": {""description"": ""Ok."", ""meaning"": 1}}"));
   begin
      Assert
        (Found.Found
         and then To_String (Found.Value) =
                  "the outcome 'Done' has the unknown key 'meaning': only "
                  & "'description' and 'data'",
         "names the key: "
         & (if Found.Found then To_String (Found.Value) else ""));
   end An_Object_Outcome_With_An_Unknown_Key_Is_Refused;

   procedure An_Outcomes_Data_Is_Checked_As_A_Field_Declaration
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Found : constant Synapse.Core.Optional_Text.Option :=
        Problem
          (Parsed
             ("{""Blocked"": {""description"": ""Cannot."","
              & " ""data"": {""x"": {""type"": ""string""},"
              & " ""y"": {""type"": ""string""}}}}"));
   begin
      Assert
        (Found.Found
         and then To_String (Found.Value) =
                  "Outcomes.Blocked.data.fields.x.description: required "
                  & "string is missing; "
                  & "Outcomes.Blocked.data.fields.y.description: required "
                  & "string is missing",
         "every problem, under the outcome: "
         & (if Found.Found then To_String (Found.Value) else ""));
      Assert
        (Problem
           (Parsed ("{""Blocked"": {""description"": ""C."", ""data"": {}}}"))
           .Found,
         "an empty mapping");
   end An_Outcomes_Data_Is_Checked_As_A_Field_Declaration;

   procedure Meaning_Of_Reads_Both_Forms (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Both : constant JSON.Value :=
        Parsed
          ("{""Done"": ""It is done."","
           & " ""Blocked"": {""description"": ""Cannot."", ""data"": {}}}");
   begin
      Assert (Meaning_Of (Both, "Done") = "It is done.", "a string");
      Assert (Meaning_Of (Both, "Blocked") = "Cannot.", "an object");
      Assert
        (Meaning_Of (Both, "Other") = ""
         and then Meaning_Of (JSON.Null_Value, "Done") = "",
         "not a word of it");
   end Meaning_Of_Reads_Both_Forms;

   procedure Data_Of_Is_Null_For_A_String_Outcome
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      use type JSON.Kind;
      Both : constant JSON.Value :=
        Parsed
          ("{""Done"": ""It is done."","
           & " ""Waiting"": {""description"": ""Not yet.""},"
           & " ""Blocked"": {""description"": ""Cannot."","
           & " ""data"": {""blocker"": {""type"": ""string"","
           & " ""description"": ""Why.""}}}}");
   begin
      Assert
        (JSON.Kind_Of (Data_Of (Both, "Done")) = JSON.JSON_Null
         and then JSON.Kind_Of (Data_Of (Both, "Waiting")) = JSON.JSON_Null
         and then JSON.Kind_Of (Data_Of (Both, "Other")) = JSON.JSON_Null,
         "null without data");
      Assert
        (JSON.Has_Member (Data_Of (Both, "Blocked"), "blocker"),
         "the field mapping with data");
   end Data_Of_Is_Null_For_A_String_Outcome;

   procedure An_Outcomes_Data_May_Be_A_List_Of_Names
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Problem
               (Parsed
                  ("{""Done"": {""description"": ""Done."","
                   & " ""data"": [""task_note"", ""remaining""]}}"))
               .Found,
         "a list of names");
   end An_Outcomes_Data_May_Be_A_List_Of_Names;

   procedure An_Outcomes_Empty_List_Of_Names_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Found : constant Synapse.Core.Optional_Text.Option :=
        Problem
          (Parsed ("{""Done"": {""description"": ""D."", ""data"": []}}"));
   begin
      Assert
        (Found.Found
         and then To_String (Found.Value) =
                  "Outcomes.Done.data: the list of names is empty",
         "names the outcome: "
         & (if Found.Found then To_String (Found.Value) else ""));
   end An_Outcomes_Empty_List_Of_Names_Is_Refused;

   procedure An_Outcomes_List_With_A_Name_Twice_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Found : constant Synapse.Core.Optional_Text.Option :=
        Problem
          (Parsed
             ("{""Done"": {""description"": ""D."","
              & " ""data"": [""a"", ""a"", 3]}}"));
   begin
      Assert
        (Found.Found
         and then To_String (Found.Value) =
                  "Outcomes.Done.data: 'a' is named twice; "
                  & "Outcomes.Done.data: item 3 is not a name",
         "every problem, joined: "
         & (if Found.Found then To_String (Found.Value) else ""));
   end An_Outcomes_List_With_A_Name_Twice_Is_Refused;

   procedure Data_Of_Gives_A_List_Of_Names_As_Written
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      use type JSON.Kind;
      Data : constant JSON.Value :=
        Data_Of
          (Parsed
             ("{""Done"": {""description"": ""D."","
              & " ""data"": [""task_note"", ""remaining""]}}"),
           "Done");
   begin
      Assert
        (JSON.Kind_Of (Data) = JSON.JSON_Array
         and then JSON.Length (Data) = 2
         and then JSON.As_String (JSON.Element (Data, 1)) = "task_note"
         and then JSON.As_String (JSON.Element (Data, 2)) = "remaining",
         "the list, in order");
   end Data_Of_Gives_A_List_Of_Names_As_Written;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Outcomes");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Word_Is_Written_Like_A_Name'Access,
         "A word is written like a name");
      Register_Routine
        (T, Declared_Outcomes_Are_Checked_As_A_Whole'Access,
         "Declared outcomes are checked as a whole");
      Register_Routine
        (T, A_Result_Is_Held_To_What_Was_Declared'Access,
         "A result is held to what was declared");
      Register_Routine
        (T, The_Test_Of_An_Outcome_Is_Recognised_Again'Access,
         "The test of an outcome is recognised again");
      Register_Routine
        (T, An_Outcome_Written_As_An_Object_Is_Accepted'Access,
         "An outcome written as an object is accepted");
      Register_Routine
        (T, An_Object_Outcome_Without_A_Description_Is_Refused'Access,
         "An object outcome without a description is refused");
      Register_Routine
        (T, An_Object_Outcome_With_An_Unknown_Key_Is_Refused'Access,
         "An object outcome with an unknown key is refused");
      Register_Routine
        (T, An_Outcomes_Data_Is_Checked_As_A_Field_Declaration'Access,
         "An outcome's data is checked as a field declaration");
      Register_Routine
        (T, Meaning_Of_Reads_Both_Forms'Access, "Meaning_Of reads both forms");
      Register_Routine
        (T, Data_Of_Is_Null_For_A_String_Outcome'Access,
         "Data_Of is null for a string outcome");
      Register_Routine
        (T, An_Outcomes_Data_May_Be_A_List_Of_Names'Access,
         "An outcome's data may be a list of names");
      Register_Routine
        (T, An_Outcomes_Empty_List_Of_Names_Is_Refused'Access,
         "An outcome's empty list of names is refused");
      Register_Routine
        (T, An_Outcomes_List_With_A_Name_Twice_Is_Refused'Access,
         "An outcome's list with a name twice is refused");
      Register_Routine
        (T, Data_Of_Gives_A_List_Of_Names_As_Written'Access,
         "Data_Of gives a list of names as written");
   end Register_Tests;

end Synapse.Pipeline.Outcomes.Tests;
