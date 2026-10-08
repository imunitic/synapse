with Ada.Strings.Unbounded;

with Acceptance.Fixtures;

package body Acceptance.Write_Node_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Body_Text : constant String :=
     "## Summary" & LF & "A node." & LF & LF & "## Links" & LF &
     "- part_of [[Other]]" & LF;

   A_Java : constant String := "mod-a/src/main/java/com/example/A.java";

   --  Files at three shapes the `## Sources` module rule treats differently:
   --  under a module's src/, under a top-level directory, and at the root.
   procedure Make_Layered_Repo (F : Fixture) is
   begin
      Make_Repo (F);
      Write_Repo_File (F, A_Java, "class A {}" & LF);
      Write_Repo_File
        (F, "mod-a/src/main/java/com/example/B.java", "class B {}" & LF);
      Write_Repo_File (F, "mod-b/src/main/java/C.java", "class C {}" & LF);
      Write_Repo_File (F, "docs/guide.md", "# doc" & LF);
      Write_Repo_File (F, "rootfile.txt", "root" & LF);
      Commit_All (F, "layered");
   end Make_Layered_Repo;

   --  `write-node`, run in the repository: the repository is found from the
   --  working directory.
   function Write
     (F : Fixture; Title : String; Paths_File : String) return Result is
     (Run_Fake
        (F, "write-node", "--title", Title, "--summary", "A one-line summary.",
         "--paths", Root (F) & "/" & Paths_File, "--body",
         Root (F) & "/body.md"));

   procedure Uncommitted_Changes_In_Own_Sources_Are_Called_Out
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Use_Schema_Content_Root (F);
      Make_Layered_Repo (F);
      Write_Root_File (F, "body.md", Body_Text);
      Write_Root_File (F, "paths.txt", A_Java & LF);
      Write_Repo_File (F, A_Java, "class A { int changed; }" & LF);
      declare
         R : constant Result := Write (F, "Dirty", "paths.txt");
         E : constant String := To_String (R.Errors);
      begin
         Assert_Exit (R, 0, "write-node");
         --  A hash of the worktree makes the recorded commit what was checked
         --  out and not a faithful baseline, which a later diff would
         --  otherwise take for content that was committed.
         Assert_Contains
           (E, "uncommitted changes in this node's sources", "the warning");
         Assert_Contains (E, "A.java", "names the file");
      end;
   end Uncommitted_Changes_In_Own_Sources_Are_Called_Out;

   procedure A_Dirty_File_Outside_The_Sources_Stays_Quiet
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Use_Schema_Content_Root (F);
      Make_Layered_Repo (F);
      Write_Root_File (F, "body.md", Body_Text);
      Write_Root_File (F, "paths.txt", "docs/guide.md" & LF);
      Write_Repo_File (F, A_Java, "class A { int changed; }" & LF);
      declare
         R : constant Result := Write (F, "Quiet", "paths.txt");
      begin
         Assert_Exit (R, 0, "write-node");
         --  Narrow on purpose: a developer mid-work elsewhere in the repo is
         --  not warned on every node write.
         Assert_Lacks (To_String (R.Errors), "uncommitted changes", "quiet");
      end;
   end A_Dirty_File_Outside_The_Sources_Stays_Quiet;

   procedure A_Title_Needing_Sanitizing_Warns (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Use_Schema_Content_Root (F);
      Make_Repo (F);
      Write_Root_File (F, "body.md", Body_Text);
      Write_Root_File (F, "paths.txt", "src/foo.aa" & LF);
      declare
         R : constant Result :=
           Write (F, "Bad " & Dash & " import/export", "paths.txt");
         E : constant String := To_String (R.Errors);
      begin
         Assert_Exit (R, 0, "write-node");
         Assert_Contains (E, "WARNING", "warns");
         Assert_Contains (E, "will not resolve", "says why");
      end;
   end A_Title_Needing_Sanitizing_Warns;

   procedure A_Clean_Title_Writes_Silently (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Use_Schema_Content_Root (F);
      Make_Repo (F);
      Write_Root_File (F, "body.md", Body_Text);
      Write_Root_File (F, "paths.txt", "src/foo.aa" & LF);
      declare
         R : constant Result :=
           Write (F, "Bad " & Dash & " import and export", "paths.txt");
      begin
         Assert_Exit (R, 0, "write-node");
         Assert_Lacks (To_String (R.Errors), "WARNING", "silent");
      end;
   end A_Clean_Title_Writes_Silently;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: write-node warnings");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Uncommitted_Changes_In_Own_Sources_Are_Called_Out'Access,
         "uncommitted changes in this node's own sources are called out");
      Register_Routine
        (T, A_Dirty_File_Outside_The_Sources_Stays_Quiet'Access,
         "a dirty file outside the node's sources stays quiet");
      Register_Routine
        (T, A_Title_Needing_Sanitizing_Warns'Access,
         "a title needing sanitizing warns that links will not resolve");
      Register_Routine
        (T, A_Clean_Title_Writes_Silently'Access,
         "a clean title writes silently");
   end Register_Tests;

end Acceptance.Write_Node_Tests;
