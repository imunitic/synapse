with Ada.Strings.Unbounded;

with Acceptance.Fixtures;

package body Acceptance.Graph_Wipe_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  A minimal two-node namespace: one node with hand-written `## Notes`
   --  (at risk), one with the section present and empty (not at risk). The
   --  exact shape `write-node` produces, since the extraction depends on the
   --  literal generated-fence markers.
   procedure Make_Namespace (F : Fixture) is
      Name : constant String := Repo_Name (F);
      Dir  : constant String := Vault (F) & "/synapse/" & Name;
   begin
      Write_File
        (Dir & "/Index.md",
         "---" & LF & "title: """ & Name & " " & Dash & " Synapse index""" &
         LF & "node_type: synapse-index" & LF & "project: " & Ns_Repo (F) &
         LF & "branch: " & Ns_Branch (F) & LF & "remote: """ &
         Repo_Remote_Or_Path (F) & """" & LF & "built_at: ""test""" & LF &
         "---" & LF & "- [[Node A]]" & LF & "- [[Node B]]" & LF);
      Write_File
        (Dir & "/Node A.md",
         "---" & LF & "title: ""Node A""" & LF &
         "summary: ""Node A in one line.""" & LF & "node_type: synapse-node" &
         LF & "---" & LF & LF & "# Node A" & LF &
         "<!-- synapse:generated:start -->" & LF & LF & "## Summary" & LF &
         "Generated stuff about Node A." & LF & LF & "## Sources" & LF &
         "- `src` (1)" & LF & "<!-- synapse:generated:end -->" & LF & LF &
         "## Notes" & LF & LF &
         "Hand-written finding worth keeping: the retry logic here is " &
         "load-bearing for the batch job, do not simplify it away.");
      Write_File
        (Dir & "/Node B.md",
         "---" & LF & "title: ""Node B""" & LF &
         "summary: ""Node B in one line.""" & LF & "node_type: synapse-node" &
         LF & "---" & LF & LF & "# Node B" & LF &
         "<!-- synapse:generated:start -->" & LF & LF & "## Summary" & LF &
         "Generated stuff about Node B." & LF & LF & "## Sources" & LF &
         "- `src` (1)" & LF & "<!-- synapse:generated:end -->" & LF & LF &
         "## Notes" & LF & LF);
      Write_File
        (Dir & "/_manifest.tsv",
         "Node A" & ASCII.HT & "^a" & ASCII.HT & LF & "Node B" & ASCII.HT &
         "^b" & ASCII.HT & LF);
   end Make_Namespace;

   procedure Wipe_Then_Rebuild_Is_Drift_Clean (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Use_Schema_Content_Root (F);
      Make_Repo (F);
      Write_Repo_File (F, "src/a.aa", "let x = 1" & LF);
      Write_Repo_File (F, "src/b.aa", "let y = 2" & LF);
      Commit_All (F, "more");
      Make_Namespace (F);
      declare
         Name    : constant String := Repo_Name (F);
         Dir     : constant String := Vault (F) & "/synapse/" & Name;
         Staging : constant String :=
           Vault (F) & "/scratchpad/" & Name & " " & Dash &
           " preserved notes before full rebuild.md";
      begin
         Assert_Exit (Run_Fake (F, "graph-wipe"), 0, "graph-wipe");
         Assert_Equal
           (Boolean'Image (Exists (Dir)), "FALSE", "the namespace is gone");
         Assert_Equal
           (Boolean'Image (Exists (Staging)), "TRUE", "the notes are staged");

         --  A fresh build over the wiped repository.
         Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
         Write_Work_File
           (F, "manifest.tsv",
            "Src " & Dash & " the source module" & ASCII.HT & "^src/" &
            ASCII.HT & LF);
         Assert_Exit (Run_Fake (F, "build-lists"), 0, "build-lists");
         Write_Work_File
           (F, "b-001.md",
            "---" & LF & "summary: Src in one line." & LF & "---" & LF & LF &
            "## Summary" & LF & "Prose for src." & LF);
         Assert_Exit (Run_Fake (F, "push-nodes"), 0, "push-nodes");
         Assert_Exit (Run_Fake (F, "build-index"), 0, "build-index");
         Assert_Exit
           (Run_Fake (F, "build-project-index"), 0, "build-project-index");

         declare
            R : constant Result := Run_Fake (F, "query", "drift");
         begin
            Assert_Exit (R, 0, "query drift");
            Assert_Equal (To_String (R.Output), "", "no drift");
         end;

         --  The rebuild does not touch the scratchpad: the staging note is
         --  the merge step's input, and only that step may consume it.
         Assert_Equal
           (Boolean'Image (Exists (Staging)), "TRUE",
            "the staging note stays");
      end;
   end Wipe_Then_Rebuild_Is_Drift_Clean;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: graph-wipe");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Wipe_Then_Rebuild_Is_Drift_Clean'Access,
         "wipe then rebuild is drift-clean and the staging note survives");
   end Register_Tests;

end Acceptance.Graph_Wipe_Tests;
