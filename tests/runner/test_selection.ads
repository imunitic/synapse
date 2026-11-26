with AUnit.Test_Filters;
with AUnit.Test_Suites;
with AUnit.Tests;
with Ada.Strings.Unbounded;

--  Which tests an AUnit runner runs: every test, the tests whose full
--  name starts with a filter, or none (only listing their names). The
--  first command-line argument decides, or SYNAPSE_TEST_FILTER when
--  there is no argument.
package Test_Selection is

   type Mode_Kind is (Run_All, Run_Filtered, List_Names);

   type Selection is record
      Mode   : Mode_Kind := Run_All;
      Filter : Ada.Strings.Unbounded.Unbounded_String;
      --  The filter text, set for Run_Filtered
   end record;

   --  The selection for a first argument (empty when none was given)
   --  and the value of SYNAPSE_TEST_FILTER (empty when unset).
   function Parse (Argument, Variable : String) return Selection;

   --  Parse of this program's command line and environment.
   function From_Command_Line return Selection;

   --  "{test case name} : {routine name}", the text a Name_Filter matches.
   function Full_Name (T : AUnit.Tests.Test'Class) return String;

   --  Prints each test's full name and runs none of them.
   type Listing_Filter is new AUnit.Test_Filters.Test_Filter with null record;
   overriding function Is_Active
     (Filter : Listing_Filter; T : AUnit.Tests.Test'Class) return Boolean;

   --  Whether a run ends with a failure exit status.
   function Failed
     (Mode : Mode_Kind; Ran : Natural; Successful : Boolean) return Boolean;

   --  Runs Suite as the command line selects and sets the exit status.
   generic
      with function Suite return AUnit.Test_Suites.Access_Test_Suite;
   procedure Run_Suite;

end Test_Selection;
