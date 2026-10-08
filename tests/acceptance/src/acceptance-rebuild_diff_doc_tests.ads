with AUnit;
with AUnit.Test_Cases;

--  The branch-identity snippet quoted in the rebuild-diff command, extracted
--  from the shipped text and run against a real repository.
package Acceptance.Rebuild_Diff_Doc_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Rebuild_Diff_Doc_Tests;
