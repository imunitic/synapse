with AUnit;
with AUnit.Test_Cases;

--  The two warning pairs of write-node that only reach real standard error.
package Acceptance.Write_Node_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Write_Node_Tests;
