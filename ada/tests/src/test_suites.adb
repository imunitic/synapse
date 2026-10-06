with Synapse.Core.Arith.Tests;
with Synapse.Core.UTF8.Tests;
with Synapse.Core.Unicode.Tests;

package body Test_Suites is

   Arith_Tests : aliased Synapse.Core.Arith.Tests.Test_Case;
   UTF8_Tests  : aliased Synapse.Core.UTF8.Tests.Test_Case;
   Unicode_Tests : aliased Synapse.Core.Unicode.Tests.Test_Case;

   function Suite return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite :=
        new AUnit.Test_Suites.Test_Suite;
   begin
      Result.Add_Test (Arith_Tests'Access);
      Result.Add_Test (UTF8_Tests'Access);
      Result.Add_Test (Unicode_Tests'Access);
      return Result;
   end Suite;

end Test_Suites;
