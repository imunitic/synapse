with Synapse.Adapters.Tree_Sitter.Tests;
with Synapse.Core.Arith.Tests;
with Synapse.Core.Regex_Lite.Tests;
with Synapse.Core.Note_Model.Tests;
with Synapse.Core.Note_Schema.Tests;
with Synapse.Core.Note_Text.Tests;
with Synapse.Core.Schema_Pattern.Tests;
with Synapse.Core.Schema_Rules.Tests;
with Synapse.Core.Schema_YAML.Tests;
with Synapse.Core.Frontmatter.Tests;
with Synapse.Core.JSON.Tests;
with Synapse.Core.JSON_Logic.Tests;
with Synapse.Core.UTF8.Tests;
with Synapse.Core.Unicode.Tests;

package body Test_Suites is

   Arith_Tests : aliased Synapse.Core.Arith.Tests.Test_Case;
   UTF8_Tests  : aliased Synapse.Core.UTF8.Tests.Test_Case;
   Unicode_Tests : aliased Synapse.Core.Unicode.Tests.Test_Case;
   Tree_Sitter_Tests : aliased Synapse.Adapters.Tree_Sitter.Tests.Test_Case;
   JSON_Tests : aliased Synapse.Core.JSON.Tests.Test_Case;
   Regex_Lite_Tests : aliased Synapse.Core.Regex_Lite.Tests.Test_Case;
   Schema_Pattern_Tests : aliased Synapse.Core.Schema_Pattern.Tests.Test_Case;
   JSON_Logic_Tests : aliased Synapse.Core.JSON_Logic.Tests.Test_Case;
   Frontmatter_Tests : aliased Synapse.Core.Frontmatter.Tests.Test_Case;
   Schema_YAML_Tests : aliased Synapse.Core.Schema_YAML.Tests.Test_Case;
   Schema_Rules_Tests : aliased Synapse.Core.Schema_Rules.Tests.Test_Case;
   Note_Schema_Tests : aliased Synapse.Core.Note_Schema.Tests.Test_Case;
   Note_Text_Tests : aliased Synapse.Core.Note_Text.Tests.Test_Case;
   Note_Model_Tests : aliased Synapse.Core.Note_Model.Tests.Test_Case;

   function Suite return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite :=
        new AUnit.Test_Suites.Test_Suite;
   begin
      Result.Add_Test (Arith_Tests'Access);
      Result.Add_Test (UTF8_Tests'Access);
      Result.Add_Test (Unicode_Tests'Access);
      Result.Add_Test (Tree_Sitter_Tests'Access);
      Result.Add_Test (JSON_Tests'Access);
      Result.Add_Test (Regex_Lite_Tests'Access);
      Result.Add_Test (Schema_Pattern_Tests'Access);
      Result.Add_Test (JSON_Logic_Tests'Access);
      Result.Add_Test (Frontmatter_Tests'Access);
      Result.Add_Test (Schema_YAML_Tests'Access);
      Result.Add_Test (Schema_Rules_Tests'Access);
      Result.Add_Test (Note_Schema_Tests'Access);
      Result.Add_Test (Note_Text_Tests'Access);
      Result.Add_Test (Note_Model_Tests'Access);
      return Result;
   end Suite;

end Test_Suites;
