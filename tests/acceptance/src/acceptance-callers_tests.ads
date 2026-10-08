with AUnit;
with AUnit.Test_Cases;

--  callers needs no vault: the real program skips the shared vault and
--  namespace preamble.
package Acceptance.Callers_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Callers_Tests;
