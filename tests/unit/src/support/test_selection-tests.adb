with AUnit.Assertions;

package body Test_Selection.Tests is

   use Ada.Strings.Unbounded;

   procedure Check
     (Got : Selection; Mode : Mode_Kind; Filter : String; Message : String);

   procedure Check
     (Got : Selection; Mode : Mode_Kind; Filter : String; Message : String)
   is
   begin
      AUnit.Assertions.Assert (Got.Mode = Mode, Message & ": mode");
      AUnit.Assertions.Assert
        (To_String (Got.Filter) = Filter,
         Message & ": filter is """ & To_String (Got.Filter) & """");
   end Check;

   procedure Runs_Every_Test (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Argument_Is_Filter (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Variable_Is_Filter (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Argument_Wins (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure List_Lists_Names (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Empty_Filter_Fails
     (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_All_Passes (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Failure_Fails (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Listing_Runs_Nothing
     (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Full_Name_Joins (T : in out AUnit.Test_Cases.Test_Case'Class);

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Test_Selection");
   end Name;

   procedure Runs_Every_Test (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Check (Parse ("", ""), Run_All, "", "no argument, no variable");
   end Runs_Every_Test;

   procedure Argument_Is_Filter
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Check
        (Parse ("Synapse.Core.Arith", ""), Run_Filtered,
         "Synapse.Core.Arith", "argument only");
   end Argument_Is_Filter;

   procedure Variable_Is_Filter
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Check
        (Parse ("", "Synapse.Core.Note"), Run_Filtered, "Synapse.Core.Note",
         "variable only");
   end Variable_Is_Filter;

   procedure Argument_Wins (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Check
        (Parse ("Synapse.Core.Arith", "Synapse.Core.Note"), Run_Filtered,
         "Synapse.Core.Arith", "argument and variable");
      Check
        (Parse ("--list", "Synapse.Core.Note"), List_Names, "",
         "--list argument and a variable");
   end Argument_Wins;

   procedure List_Lists_Names (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Check (Parse ("--list", ""), List_Names, "", "--list argument");
      Check (Parse ("", "--list"), List_Names, "", "--list variable");
   end List_Lists_Names;

   procedure Empty_Filter_Fails
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      AUnit.Assertions.Assert
        (Failed (Run_Filtered, Ran => 0, Successful => True),
         "a filter that ran no test fails");
      AUnit.Assertions.Assert
        (not Failed (Run_Filtered, Ran => 1, Successful => True),
         "a filter that ran a passing test passes");
   end Empty_Filter_Fails;

   procedure Run_All_Passes (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      AUnit.Assertions.Assert
        (not Failed (Run_All, Ran => 5, Successful => True),
         "every test ran and passed");
      AUnit.Assertions.Assert
        (not Failed (Run_All, Ran => 0, Successful => True),
         "no test ran without a filter");
      AUnit.Assertions.Assert
        (not Failed (List_Names, Ran => 0, Successful => True),
         "a listing runs no test and passes");
   end Run_All_Passes;

   procedure Failure_Fails (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      for Mode in Mode_Kind loop
         AUnit.Assertions.Assert
           (Failed (Mode, Ran => 3, Successful => False),
            Mode_Kind'Image (Mode) & ": a failed test fails");
      end loop;
   end Failure_Fails;

   procedure Listing_Runs_Nothing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Listing : Listing_Filter;
   begin
      AUnit.Assertions.Assert
        (not Listing.Is_Active (T), "a listed test is not run");
   end Listing_Runs_Nothing;

   procedure Full_Name_Joins (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      AUnit.Assertions.Assert
        (Full_Name (T)
         = "Test_Selection : The full name joins the case and the routine",
         "full name is """ & Full_Name (T) & """");
   end Full_Name_Joins;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Runs_Every_Test'Access,
         "No argument and no variable runs every test");
      Register_Routine
        (T, Argument_Is_Filter'Access, "An argument is a filter");
      Register_Routine
        (T, Variable_Is_Filter'Access,
         "The variable is the filter when there is no argument");
      Register_Routine
        (T, Argument_Wins'Access, "An argument wins over the variable");
      Register_Routine (T, List_Lists_Names'Access, "--list lists the names");
      Register_Routine
        (T, Empty_Filter_Fails'Access, "A filter that ran no test fails");
      Register_Routine
        (T, Run_All_Passes'Access,
         "A run of every test passes when none failed, also when none ran");
      Register_Routine
        (T, Failure_Fails'Access, "A failed test fails in every mode");
      Register_Routine
        (T, Listing_Runs_Nothing'Access, "Listing runs nothing");
      Register_Routine
        (T, Full_Name_Joins'Access,
         "The full name joins the case and the routine");
   end Register_Tests;

end Test_Selection.Tests;
