with Acceptance.Fixtures;

package body Acceptance.Staleness_Tests is

   use Acceptance.Fixtures;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  A node whose frontmatter has every shape a re-serialising writer
   --  mangles:
   --  a title long enough to be folded, quoted values, and an all-digit `hash`
   --  that YAML takes for a float.
   procedure Write_Synapse_Node (F : Fixture; Namespace, Node, Stale : String)
   is
   begin
      Write_File
        (Vault (F) & "/synapse/" & Namespace & "/" & Node,
         "---" & LF &
         "title: ""A deliberately long node title that a re-serialising " &
          "writer " &
         "would fold across two lines""" & LF & "node_type: synapse-node" &
         LF & "project: " & Namespace & LF & "sources:" & LF &
         "  - path: src/foo.aa" & LF &
         "    hash: 1111111111111111111111111111111111111111" & LF &
         "sources_digest: """ &
         "2222222222222222222222222222222222222222222222222222222222222222""" &
         LF & "stale: " & Stale & LF & "built_at: ""2026-08-03 16:15""" & LF &
         "---" & LF & LF & "# A node" & LF & LF &
         "Body text, including a decoy: stale: false" & LF);
   end Write_Synapse_Node;

   procedure A_File_Of_A_Node_Gets_Its_Stale_Line_Rewritten
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
      Make_Repo (F);
      declare
         Name : constant String := Repo_Name (F);
         Node : constant String :=
           Vault (F) & "/synapse/" & Name & "/Foo Node.md";
      begin
         Write_Synapse_Index (F, Name, Repo_Remote_Or_Path (F));
         Write_Synapse_Node (F, Name, "Foo Node.md", "false");
         Write_Index_Bin
           (F, Work (F), "src/foo.aa" & ASCII.HT & "Foo Node.md" & LF);
         declare
            R    : constant Result :=
              Run_Hook_Stdin
                (F,
                 "{""tool_input"":{""file_path"":""" & Repo (F) &
                 "/src/foo.aa""}}",
                 "staleness");
            Text : constant String := Read_File (Node);
         begin
            Assert_Exit (R, 0, "staleness");
            Assert_Contains (Text, "stale: true", "the stale line");
            --  Only the line is rewritten: the hash the YAML would take for
            --  a float, and the decoy in the body, come through unchanged.
            Assert_Contains
              (Text, "hash: 1111111111111111111111111111111111111111",
               "the hash is untouched");
            Assert_Contains
              (Text, "decoy: stale: false", "the body is untouched");
         end;
      end;
   end A_File_Of_A_Node_Gets_Its_Stale_Line_Rewritten;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: staleness hook");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_File_Of_A_Node_Gets_Its_Stale_Line_Rewritten'Access,
         "a file mapped to a node gets that node's stale line rewritten");
   end Register_Tests;

end Acceptance.Staleness_Tests;
