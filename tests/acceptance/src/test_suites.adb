with Acceptance.Cli_Usage_Tests;
with Acceptance.Callers_Tests;
with Acceptance.Graph_Wipe_Tests;
with Acceptance.Grounding_Tests;
with Acceptance.Lint_Tests;
with Acceptance.Diagrams_Reference_Tests;
with Acceptance.Cli_Reference_Tests;
with Acceptance.Rebuild_Diff_Tests;
with Acceptance.Rebuild_Diff_Doc_Tests;
with Acceptance.Legacy_Commands_Tests;
with Acceptance.Tags_Lock_Tests;
with Acceptance.Query_Tests;
with Acceptance.Index_Namespace_Tests;
with Acceptance.Git_Store_Tests;
with Acceptance.Pipeline_Tests;
with Acceptance.Prompt_Context_Tests;
with Acceptance.Staleness_Tests;
with Acceptance.Write_Node_Tests;

package body Test_Suites is

   Callers        : aliased Acceptance.Callers_Tests.Test_Case;
   Graph_Wipe     : aliased Acceptance.Graph_Wipe_Tests.Test_Case;
   Grounding      : aliased Acceptance.Grounding_Tests.Test_Case;
   GitStore       : aliased Acceptance.Git_Store_Tests.Test_Case;
   IndexNs        : aliased Acceptance.Index_Namespace_Tests.Test_Case;
   Query          : aliased Acceptance.Query_Tests.Test_Case;
   TagsLock       : aliased Acceptance.Tags_Lock_Tests.Test_Case;
   Legacy         : aliased Acceptance.Legacy_Commands_Tests.Test_Case;
   RebuildDoc     : aliased Acceptance.Rebuild_Diff_Doc_Tests.Test_Case;
   RebuildDiff    : aliased Acceptance.Rebuild_Diff_Tests.Test_Case;
   CliRef         : aliased Acceptance.Cli_Reference_Tests.Test_Case;
   DiagramsRef    : aliased Acceptance.Diagrams_Reference_Tests.Test_Case;
   Lint           : aliased Acceptance.Lint_Tests.Test_Case;
   Cli_Usage      : aliased Acceptance.Cli_Usage_Tests.Test_Case;
   Pipeline       : aliased Acceptance.Pipeline_Tests.Test_Case;
   Prompt_Context : aliased Acceptance.Prompt_Context_Tests.Test_Case;
   Staleness      : aliased Acceptance.Staleness_Tests.Test_Case;
   Write_Node     : aliased Acceptance.Write_Node_Tests.Test_Case;

   function Suite return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite :=
        new AUnit.Test_Suites.Test_Suite;
   begin
      Result.Add_Test (Cli_Usage'Access);
      Result.Add_Test (Pipeline'Access);
      Result.Add_Test (Write_Node'Access);
      Result.Add_Test (Prompt_Context'Access);
      Result.Add_Test (Staleness'Access);
      Result.Add_Test (Grounding'Access);
      Result.Add_Test (Graph_Wipe'Access);
      Result.Add_Test (Callers'Access);
      Result.Add_Test (Lint'Access);
      Result.Add_Test (DiagramsRef'Access);
      Result.Add_Test (CliRef'Access);
      Result.Add_Test (RebuildDiff'Access);
      Result.Add_Test (RebuildDoc'Access);
      Result.Add_Test (Legacy'Access);
      Result.Add_Test (TagsLock'Access);
      Result.Add_Test (Query'Access);
      Result.Add_Test (IndexNs'Access);
      Result.Add_Test (GitStore'Access);
      return Result;
   end Suite;

end Test_Suites;
