with AUnit;
with AUnit.Test_Cases;

--  The real pipeline, build-lists to push-nodes to build-index to
--  build-project-index to query, through real subprocess boundaries. Every
--  bug this chain has had was a mismatch between two steps, invisible until
--  the whole of it runs.
package Acceptance.Pipeline_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Pipeline_Tests;
