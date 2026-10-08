with AUnit;
with AUnit.Test_Cases;

--  The argument and exit-code contract of the commands whose logic the unit
--  suite covers: a missing argument or a bad flag is exit 2, help is exit 0,
--  and none of it needs a grammar.
package Acceptance.Cli_Usage_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Cli_Usage_Tests;
