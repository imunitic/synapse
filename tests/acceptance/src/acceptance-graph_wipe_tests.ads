with AUnit;
with AUnit.Test_Cases;

--  graph-wipe and a fresh rebuild, end to end.
package Acceptance.Graph_Wipe_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Graph_Wipe_Tests;
