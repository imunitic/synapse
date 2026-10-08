with AUnit;
with AUnit.Test_Cases;

package Synapse.Core.Tag_Line.Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String;

   overriding
   procedure Register_Tests (T : in out Test_Case);

end Synapse.Core.Tag_Line.Tests;
