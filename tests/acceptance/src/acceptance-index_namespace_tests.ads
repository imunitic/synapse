with AUnit;
with AUnit.Test_Cases;

--  The read forms of index, addressing another namespace's built index
--  directly with --namespace.
package Acceptance.Index_Namespace_Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Test_Case);

end Acceptance.Index_Namespace_Tests;
