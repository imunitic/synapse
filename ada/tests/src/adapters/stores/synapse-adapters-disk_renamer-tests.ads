with AUnit;
with AUnit.Test_Cases;

package Synapse.Adapters.Disk_Renamer.Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String;

   overriding
   procedure Register_Tests (T : in out Test_Case);

end Synapse.Adapters.Disk_Renamer.Tests;
