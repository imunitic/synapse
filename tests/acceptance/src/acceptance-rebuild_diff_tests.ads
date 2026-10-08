with AUnit;
with AUnit.Test_Cases;

--  The rebuild and diff pipeline against a repository with real history and
--  real drift, through real subprocess boundaries.
package Acceptance.Rebuild_Diff_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Rebuild_Diff_Tests;
