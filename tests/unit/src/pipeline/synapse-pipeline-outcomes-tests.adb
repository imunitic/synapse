with Ada.Strings.Unbounded;

with AUnit.Assertions;

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
   end Register_Tests;

end Synapse.Pipeline.Outcomes.Tests;
