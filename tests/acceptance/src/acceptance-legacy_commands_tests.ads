with AUnit;
with AUnit.Test_Cases;

--  Every command a shipped instruction, an injected context or a generated
--  document names is checked against the program's own help.
package Acceptance.Legacy_Commands_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Legacy_Commands_Tests;
