with AUnit;
with AUnit.Test_Cases;

--  What query needs a real process for: usage exits, a real branch switch, and
--  a real remote mismatch.
package Acceptance.Query_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Query_Tests;
