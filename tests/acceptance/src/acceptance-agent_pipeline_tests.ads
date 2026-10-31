with AUnit;
with AUnit.Test_Cases;

--  `synapse-pipeline` end to end: the built program against definitions,
--  scripts and stand-in harness programs in a scratch tree.

package Acceptance.Agent_Pipeline_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String;

   overriding
   procedure Register_Tests (T : in out Test_Case);

end Acceptance.Agent_Pipeline_Tests;
