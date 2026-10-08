with Ada.Strings.Unbounded;

with Acceptance.Fixtures;

package body Acceptance.Query_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   procedure Unknown_Or_Missing_Subcommand_Exits_2
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F);
      Assert_Exit (Run_Fake (F, "query", "bogus"), 2, "unknown subcommand");
      Assert_Exit (Run_Fake (F, "query"), 2, "no subcommand");
   end Unknown_Or_Missing_Subcommand_Exits_2;

   --  A namespace describes one branch, so another branch has none. Exit 1 is
   --  "could not run", never "clean": clean would read as a graph that
   --  matches, the conflation the per-branch keying exists to remove. A real
   --  branch switch is needed, because the identity of a checkout is read
   --  from its `.git/HEAD`.
   procedure Drift_On_Another_Branch_Exits_1 (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
      Write_Repo_File (F, "mod-a/a.bb", "class A {}" & LF);
      Write_Repo_File (F, "mod-a/b.bb", "class B {}" & LF);
      Write_Repo_File (F, "docs/guide.md", "# guide" & LF);
      Git_Commit (F, "two-areas");
      declare
         Name : constant String := Repo_Name (F);
         Base : constant String := Git_Output (F, "rev-parse", "HEAD");
         Hash : constant String := Git_Output (F, "hash-object", "mod-a/a.bb");
      begin
         Write_Synapse_Index (F, Name, Repo_Remote_Or_Path (F));
         Write_File
           (Vault (F) & "/synapse/" & Name & "/Mod A.md",
            "---" & LF & "title: ""Mod A""" & LF & "summary: ""One line.""" &
            LF & "node_type: synapse-node" & LF & "project: " & Name & LF &
            "sources:" & LF & "  - path: mod-a/a.bb" & LF & "    hash: " &
            Hash & LF & "sources_digest: notchecked" & LF & "stale: false" &
            LF & "built_at: ""2026-01-01 00:00""" & LF & "commit: " & Base &
            LF & "---" & LF & LF & "# Mod A" & LF &
            "<!-- synapse:generated:start -->" & LF & "body" & LF &
            "<!-- synapse:generated:end -->" & LF & LF & "## Notes" & LF);
         Write_Index_Bin
           (F, Work (F), "mod-a/a.bb" & ASCII.HT & "Mod A.md" & LF);

         Assert_Exit (Run_Synapse (F, "query", "drift"), 0, "on its branch");

         declare
            Ignore : constant Result :=
              Git (F, "checkout", "-q", "-b", "some-other-branch");
            R      : constant Result := Run_Synapse (F, "query", "drift");
         begin
            Assert_Exit (R, 1, "on another branch");
            Assert_Lacks
              (Both (R), "is not an ancestor of HEAD",
               "no baseline complaint");
         end;
      end;
   end Drift_On_Another_Branch_Exits_1;

   --  An implicit resolve, unlike `--namespace`, compares the recorded remote
   --  of the namespace with the real remote of the checkout it is run from.
   procedure A_Namespace_Of_Another_Remote_Exits_1
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Write_Repo_File (F, "src/foo.aa", "let x = 1" & LF);
      declare
         Ignore : constant Result :=
           Git
             (F, "remote", "add", "origin", "ssh://git@example.com/mine.git");
      begin
         null;
      end;
      Git_Commit (F, "init");
      Write_Synapse_Index
        (F, Repo_Name (F), "ssh://git@example.com/SOMEONE-ELSE.git");
      Write_Index_Bin
        (F, Work (F), "src/foo.aa" & ASCII.HT & "Foo Node.md" & LF);
      Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
      declare
         R : constant Result := Run_Synapse (F, "query", "stale");
      begin
         Assert_Exit (R, 1, "query stale");
         Assert_Equal (To_String (R.Output), "", "nothing is reported");
      end;
   end A_Namespace_Of_Another_Remote_Exits_1;

   --  A session reaching for `symbol` usually lacks the node: the error names
   --  the command that needs none.
   procedure Symbol_With_No_Node_Points_At_Callers
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Write_Repo_File (F, "src/foo.aa", "let x = 1" & LF);
      declare
         Ignore : constant Result :=
           Git
             (F, "remote", "add", "origin", "ssh://git@example.com/mine.git");
      begin
         null;
      end;
      Git_Commit (F, "init");
      Write_Synapse_Index (F, Repo_Name (F), "ssh://git@example.com/mine.git");
      Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
      declare
         R : constant Result :=
           Run_Synapse
             (F, "query", "--namespace", Repo_Name (F), "symbol", "Foo");
      begin
         Assert_Exit (R, 2, "query symbol");
         Assert_Contains
           (To_String (R.Errors), "`synapse callers Foo --all`",
            "the pointer");
      end;
   end Symbol_With_No_Node_Points_At_Callers;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: query");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Unknown_Or_Missing_Subcommand_Exits_2'Access,
         "an unknown subcommand and no subcommand both exit 2");
      Register_Routine
        (T, Drift_On_Another_Branch_Exits_1'Access,
         "drift on a branch the namespace does not describe exits 1");
      Register_Routine
        (T, A_Namespace_Of_Another_Remote_Exits_1'Access,
         "stale: a namespace of a different remote exits 1, reports nothing");
      Register_Routine
        (T, Symbol_With_No_Node_Points_At_Callers'Access,
         "symbol with no node exits 2 and points at callers --all");
   end Register_Tests;

end Acceptance.Query_Tests;
