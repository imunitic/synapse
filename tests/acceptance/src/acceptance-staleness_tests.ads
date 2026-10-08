with AUnit;
with AUnit.Test_Cases;

--  The staleness hook's real stdin round trip.
package Acceptance.Staleness_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Staleness_Tests;
