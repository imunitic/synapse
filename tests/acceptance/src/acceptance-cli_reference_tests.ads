with AUnit;
with AUnit.Test_Cases;

--  docs/synapse/generate-cli-reference.sh and its --check mode, against the
--  real programs' help.
package Acceptance.Cli_Reference_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Cli_Reference_Tests;
