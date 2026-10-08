with AUnit;
with AUnit.Test_Cases;

--  The prompt-context hook's stdin payload and its disable switch: what only a
--  real process exercises.
package Acceptance.Prompt_Context_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Prompt_Context_Tests;
