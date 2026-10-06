with Synapse.Adapters.Tree_Sitter.Tests;
with Synapse.Core.Arith.Tests;
with Synapse.Core.Regex_Lite.Tests;
with Synapse.Adapters.Disk_Store.Tests;
with Synapse.Adapters.Dir_Lock.Tests;
with Synapse.Adapters.Conf_Files.Tests;
with Synapse.Adapters.Disk_Link_Graph.Tests;
with Synapse.Adapters.Disk_Renamer.Tests;
with Synapse.Adapters.Git_Capabilities.Tests;
with Synapse.Adapters.Fake_Store.Tests;
with Synapse.Adapters.Git_Identity.Tests;
with Synapse.Adapters.Schema_Loader.Tests;
with Synapse.Adapters.Store_Resolve.Tests;
with Synapse.Adapters.Schema_Validation_Store.Tests;
with Synapse.Adapters.System_Clock.Tests;
with Synapse.Adapters.System_Variables.Tests;
with Synapse.Core.Conf.Tests;
with Synapse.Adapters.Git_Store.Tests;
with Synapse.Adapters.Git_Sync.Tests;
with Synapse.Adapters.System_Process.Tests;
with Synapse.Core.Node_Path.Tests;
with Synapse.Core.Path_Filter.Tests;
with Synapse.Core.Note_Check.Tests;
with Synapse.Core.Note_Model.Tests;
with Synapse.Core.Note_Operators.Tests;
with Synapse.Core.Prose.Tests;
with Synapse.Core.Text_Search.Tests;
with Synapse.Core.Wikilinks.Tests;
with Synapse.Core.Emit.Tests;
with Synapse.Core.Tag_Line.Tests;
with Synapse.Core.Refs.Tests;
with Synapse.Core.Kind_Synonyms.Tests;
with Synapse.Core.Fence_Languages.Tests;
with Synapse.Core.Enumerate.Tests;
with Synapse.Adapters.Graph_Confs.Tests;
with Synapse.Adapters.File_Byte_Source.Tests;
with Synapse.Adapters.Memory_Byte_Source.Tests;
with Synapse.Core.Graph_Model.Tests;
with Synapse.Core.Hashing.Tests;
with Synapse.Core.Line_Slice.Tests;
with Synapse.Core.Node_Format.Tests;
with Synapse.Core.Node_Query.Tests;
with Synapse.Core.Identity.Tests;
with Synapse.Core.Project_Index.Tests;
with Synapse.Core.Words.Tests;
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

   Arith_Tests              : aliased Synapse.Core.Arith.Tests.Test_Case;
   UTF8_Tests               : aliased Synapse.Core.UTF8.Tests.Test_Case;
   Unicode_Tests            : aliased Synapse.Core.Unicode.Tests.Test_Case;
   Tree_Sitter_Tests : aliased Synapse.Adapters.Tree_Sitter.Tests.Test_Case;
   JSON_Tests               : aliased Synapse.Core.JSON.Tests.Test_Case;
   Regex_Lite_Tests         : aliased Synapse.Core.Regex_Lite.Tests.Test_Case;
   Schema_Pattern_Tests : aliased Synapse.Core.Schema_Pattern.Tests.Test_Case;
   JSON_Logic_Tests         : aliased Synapse.Core.JSON_Logic.Tests.Test_Case;
   Frontmatter_Tests        : aliased Synapse.Core.Frontmatter.Tests.Test_Case;
   Schema_YAML_Tests        : aliased Synapse.Core.Schema_YAML.Tests.Test_Case;
   Schema_Rules_Tests : aliased Synapse.Core.Schema_Rules.Tests.Test_Case;
   Note_Schema_Tests        : aliased Synapse.Core.Note_Schema.Tests.Test_Case;
   Note_Text_Tests          : aliased Synapse.Core.Note_Text.Tests.Test_Case;
   Note_Model_Tests         : aliased Synapse.Core.Note_Model.Tests.Test_Case;
   Note_Check_Tests         : aliased Synapse.Core.Note_Check.Tests.Test_Case;
   Node_Path_Tests          : aliased Synapse.Core.Node_Path.Tests.Test_Case;
   Text_Search_Tests        : aliased Synapse.Core.Text_Search.Tests.Test_Case;
   Words_Tests              : aliased Synapse.Core.Words.Tests.Test_Case;
   Fake_Store_Tests : aliased Synapse.Adapters.Fake_Store.Tests.Test_Case;
   Disk_Store_Tests : aliased Synapse.Adapters.Disk_Store.Tests.Test_Case;
   Path_Filter_Tests        : aliased Synapse.Core.Path_Filter.Tests.Test_Case;
   Dir_Lock_Tests : aliased Synapse.Adapters.Dir_Lock.Tests.Test_Case;
   System_Process_Tests     :
     aliased Synapse.Adapters.System_Process.Tests.Test_Case;
   Git_Sync_Tests : aliased Synapse.Adapters.Git_Sync.Tests.Test_Case;
   Git_Store_Tests : aliased Synapse.Adapters.Git_Store.Tests.Test_Case;
   System_Variables_Tests   :
     aliased Synapse.Adapters.System_Variables.Tests.Test_Case;
   Conf_Files_Tests : aliased Synapse.Adapters.Conf_Files.Tests.Test_Case;
   Schema_Loader_Tests      :
     aliased Synapse.Adapters.Schema_Loader.Tests.Test_Case;
   Validation_Store_Tests   :
     aliased Synapse.Adapters.Schema_Validation_Store.Tests.Test_Case;
   System_Clock_Tests : aliased Synapse.Adapters.System_Clock.Tests.Test_Case;
   Store_Resolve_Tests      :
     aliased Synapse.Adapters.Store_Resolve.Tests.Test_Case;
   Conf_Tests               : aliased Synapse.Core.Conf.Tests.Test_Case;
   Disk_Link_Graph_Tests    :
     aliased Synapse.Adapters.Disk_Link_Graph.Tests.Test_Case;
   Disk_Renamer_Tests : aliased Synapse.Adapters.Disk_Renamer.Tests.Test_Case;
   Git_Capabilities_Tests   :
     aliased Synapse.Adapters.Git_Capabilities.Tests.Test_Case;
   Git_Identity_Tests : aliased Synapse.Adapters.Git_Identity.Tests.Test_Case;
   Emit_Tests               : aliased Synapse.Core.Emit.Tests.Test_Case;
   Hashing_Tests            : aliased Synapse.Core.Hashing.Tests.Test_Case;
   Line_Slice_Tests         : aliased Synapse.Core.Line_Slice.Tests.Test_Case;
   Node_Format_Tests        : aliased Synapse.Core.Node_Format.Tests.Test_Case;
   Node_Query_Tests         : aliased Synapse.Core.Node_Query.Tests.Test_Case;
   Tag_Line_Tests           : aliased Synapse.Core.Tag_Line.Tests.Test_Case;
   Refs_Tests               : aliased Synapse.Core.Refs.Tests.Test_Case;
   Kind_Synonyms_Tests : aliased Synapse.Core.Kind_Synonyms.Tests.Test_Case;
   Fence_Languages_Tests    :
     aliased Synapse.Core.Fence_Languages.Tests.Test_Case;
   Enumerate_Tests          : aliased Synapse.Core.Enumerate.Tests.Test_Case;
   Graph_Confs_Tests : aliased Synapse.Adapters.Graph_Confs.Tests.Test_Case;
   File_Byte_Source_Tests   :
     aliased Synapse.Adapters.File_Byte_Source.Tests.Test_Case;
   Memory_Byte_Source_Tests :
     aliased Synapse.Adapters.Memory_Byte_Source.Tests.Test_Case;
   Graph_Model_Tests        : aliased Synapse.Core.Graph_Model.Tests.Test_Case;
   Identity_Tests           : aliased Synapse.Core.Identity.Tests.Test_Case;
   Project_Index_Tests : aliased Synapse.Core.Project_Index.Tests.Test_Case;
   Wikilinks_Tests          : aliased Synapse.Core.Wikilinks.Tests.Test_Case;
   Prose_Tests              : aliased Synapse.Core.Prose.Tests.Test_Case;
   Note_Operators_Tests : aliased Synapse.Core.Note_Operators.Tests.Test_Case;

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
      Result.Add_Test (Prose_Tests'Access);
      Result.Add_Test (Wikilinks_Tests'Access);
      Result.Add_Test (Git_Identity_Tests'Access);
      Result.Add_Test (Graph_Model_Tests'Access);
      Result.Add_Test (Memory_Byte_Source_Tests'Access);
      Result.Add_Test (Tag_Line_Tests'Access);
      Result.Add_Test (Refs_Tests'Access);
      Result.Add_Test (Kind_Synonyms_Tests'Access);
      Result.Add_Test (Fence_Languages_Tests'Access);
      Result.Add_Test (Enumerate_Tests'Access);
      Result.Add_Test (Graph_Confs_Tests'Access);
      Result.Add_Test (File_Byte_Source_Tests'Access);
      Result.Add_Test (Emit_Tests'Access);
      Result.Add_Test (Hashing_Tests'Access);
      Result.Add_Test (Line_Slice_Tests'Access);
      Result.Add_Test (Node_Format_Tests'Access);
      Result.Add_Test (Node_Query_Tests'Access);
      Result.Add_Test (Identity_Tests'Access);
      Result.Add_Test (Project_Index_Tests'Access);
      Result.Add_Test (Disk_Renamer_Tests'Access);
      Result.Add_Test (Git_Capabilities_Tests'Access);
      Result.Add_Test (Disk_Link_Graph_Tests'Access);
      Result.Add_Test (System_Variables_Tests'Access);
      Result.Add_Test (Conf_Tests'Access);
      Result.Add_Test (Store_Resolve_Tests'Access);
      Result.Add_Test (Schema_Loader_Tests'Access);
      Result.Add_Test (Validation_Store_Tests'Access);
      Result.Add_Test (System_Clock_Tests'Access);
      Result.Add_Test (Conf_Files_Tests'Access);
      Result.Add_Test (Git_Store_Tests'Access);
      Result.Add_Test (Git_Sync_Tests'Access);
      Result.Add_Test (Dir_Lock_Tests'Access);
      Result.Add_Test (System_Process_Tests'Access);
      Result.Add_Test (Path_Filter_Tests'Access);
      Result.Add_Test (Fake_Store_Tests'Access);
      Result.Add_Test (Disk_Store_Tests'Access);
      Result.Add_Test (Node_Path_Tests'Access);
      Result.Add_Test (Text_Search_Tests'Access);
      Result.Add_Test (Words_Tests'Access);
      Result.Add_Test (Note_Check_Tests'Access);
      Result.Add_Test (Note_Operators_Tests'Access);
      return Result;
   end Suite;

end Test_Suites;
