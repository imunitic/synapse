with Ada.Containers;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Acceptance.Fixtures;

package body Acceptance.Rebuild_Diff_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Alpha : constant String := "Alpha " & Dash & " the first module";
   Beta  : constant String := "Beta " & Dash & " the second module";
   Gamma : constant String := "Gamma " & Dash & " the third module";
   Docs  : constant String := "Docs " & Dash & " the documentation";

   function Image (N : Natural; Width : Positive := 1) return String is
      Text : constant String :=
        Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Left);
   begin
      return (1 .. Integer'Max (0, Width - Text'Length) => '0') & Text;
   end Image;

   procedure Ignore (R : Result) is
      pragma Unreferenced (R);
   begin
      null;
   end Ignore;

   procedure Make_Module (F : Fixture; Module : String) is
   begin
      for I in 1 .. 20 loop
         declare
            N : constant String := Module & Image (I, 2);
         begin
            Write_Repo_File
              (F, "mod-" & Module & "/src/main/java/" & N & ".java",
               "class " & N & " { int v = " & Image (I) & "; }" & LF);
         end;
      end loop;
   end Make_Module;

   --  Three modules of 20 files each, so that a two-file change is 10% of a
   --  node and a whole-module change is not.
   procedure Make_Project (F : Fixture) is
   begin
      Make_Repo (F);
      Make_Module (F, "alpha");
      Make_Module (F, "beta");
      Make_Module (F, "gamma");
      for I in 1 .. 3 loop
         Write_Repo_File
           (F, "docs/d" & Image (I) & ".md", "# doc " & Image (I) & LF);
      end loop;
      Commit_All (F, "project");
      Write_Work_File
        (F, "manifest.tsv",
         Alpha & HT & "^mod-alpha/" & HT & LF & Beta & HT & "^mod-beta/" & HT &
         LF & Gamma & HT & "^mod-gamma/" & HT & LF & Docs & HT & "^docs/" &
         HT & LF);
   end Make_Project;

   function Title_Of (F : Fixture; Number : String) return String is
     (Trim (Read_File (Work (F) & "/lists/" & Number & ".title")));

   procedure Author_Body (F : Fixture; Number : String) is
      Title : constant String := Title_Of (F, Number);
   begin
      Write_Work_File
        (F, "b-" & Number & ".md",
         "---" & LF & "summary: " & Title & " in one line." & LF & "---" & LF &
         LF & "## Summary" & LF & "Prose for " & Title & "." & LF & LF &
         "## Crux" & LF & "```java" & LF & "class alpha1 { int v = 1; }" & LF &
         "```" & LF);
   end Author_Body;

   --  The full four-step build, as `/synapse-init` runs it.
   procedure Build_Namespace (F : Fixture) is
   begin
      Ignore (Run_Fake (F, "build-lists"));
      Author_Body (F, "001");
      Author_Body (F, "002");
      Author_Body (F, "003");
      Author_Body (F, "004");
      Ignore (Run_Fake (F, "push-nodes"));
      Ignore (Run_Fake (F, "build-index"));
      Ignore (Run_Fake (F, "build-project-index"));
   end Build_Namespace;

   procedure Set_Up (F : in out Fixture) is
   begin
      Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
      Use_Schema_Content_Root (F);
   end Set_Up;

   function Full_Prose (F : Fixture; Title : String) return String is
     (Prose_Before_Sources
        (To_String (Run_Fake (F, "query", "body", Title, "--full").Output)));

   --  Writes a node again from prose in a file and the list it was built
   --  from.
   function Rewrite
     (F : Fixture; Title, Body_File, List : String) return Result is
     (Run_Fake
        (F, "write-node", "--title", Title, "--summary",
         Title & " in one line.", "--paths", List, "--body", Body_File));

   procedure Rename_Beta (F : Fixture) is
   begin
      Ignore
        (Git (F, "mv", "mod-beta/src/main/java", "mod-beta/src/main/kotlin"));
   end Rename_Beta;

   procedure Add_Gamma (F : Fixture; First, Last : Positive) is
   begin
      for I in First .. Last loop
         Write_Repo_File
           (F, "mod-gamma/src/main/java/gamma" & Image (I) & ".java",
            "class gamma" & Image (I) & " {}" & LF);
      end loop;
   end Add_Gamma;

   procedure A_Fresh_Namespace_Has_No_Drift (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Make_Project (F);
      Build_Namespace (F);
      declare
         Drift : constant Result := Run_Fake (F, "query", "drift");
         Stale : constant Result := Run_Fake (F, "query", "stale");
      begin
         Assert_Exit (Drift, 0, "drift");
         Assert_Equal (To_String (Drift.Output), "", "drift output");
         Assert_Exit (Stale, 0, "stale");
         Assert_Equal (To_String (Stale.Output), "", "stale output");
      end;
   end A_Fresh_Namespace_Has_No_Drift;

   procedure Mixed_Drift_Is_Classified_Per_Node (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Make_Project (F);
      Build_Namespace (F);

      --  Alpha: 2 of 20 files edited, 10%, the patch case.
      Write_Repo_File
        (F, "mod-alpha/src/main/java/alpha01.java",
         "class alpha01 { int v = 99; }" & LF);
      Write_Repo_File
        (F, "mod-alpha/src/main/java/alpha02.java",
         "class alpha02 { int v = 99; }" & LF);
      --  Beta: every file moved, content untouched, the reseat case.
      Rename_Beta (F);
      --  Gamma: one deletion and three additions under the existing pattern.
      Ignore (Git (F, "rm", "-q", "mod-gamma/src/main/java/gamma01.java"));
      Add_Gamma (F, 21, 23);
      --  A whole new subsystem that no manifest pattern covers.
      Write_Repo_File
        (F, "mod-delta/src/main/java/delta1.java", "class delta1 {}" & LF);
      Commit_All (F, "drift");

      declare
         R : constant Result := Run_Fake (F, "query", "drift");
         O : constant String := To_String (R.Output);
      begin
         Assert_Exit (R, 0, "drift");
         Assert_Contains
           (O, Alpha & HT & "content changed in 2 of its files", "alpha");
         Assert_Contains
           (O, Beta & HT & "20 of its files were renamed", "beta");
         Assert_Contains (O, Gamma & HT & "1 of its files are gone", "gamma");
         Assert_Contains
           (O, "3 new paths already match a manifest pattern", "claimed");
         Assert_Contains
           (O, "1 new paths match no manifest pattern", "unclaimed");
         Assert_Contains (O, "mod-delta/src/main/java/delta1.java", "named");
         Assert_Lacks (O, Docs & HT & "content changed", "docs");
      end;
      Assert_Equal
        (Trim
           (To_String
              (Run_Fake (F, "query", "sources", Alpha, "--count").Output)),
         "20", "alpha keeps its files");
   end Mixed_Drift_Is_Classified_Per_Node;

   procedure Reseat_Rebuilds_A_Renamed_Node_From_Its_Own_Body
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Make_Project (F);
      Build_Namespace (F);
      declare
         Before : constant String := Full_Prose (F, Beta);
      begin
         Rename_Beta (F);
         Commit_All (F, "rename-beta");
         Assert_Contains
           (To_String (Run_Fake (F, "query", "drift").Output),
            Beta & HT & "20 of its files were renamed",
            "drift sees the rename");

         Ignore (Run_Fake (F, "build-lists", "--reenumerate"));
         Write_Work_File (F, "reseat.md", Full_Prose (F, Beta));
         Assert_Exit
           (Rewrite
              (F, Beta, Work (F) & "/reseat.md", Work (F) & "/lists/002.txt"),
            0, "write-node");
         Assert_Equal (Full_Prose (F, Beta), Before, "the prose is unchanged");

         Ignore (Run_Fake (F, "build-index"));
         Assert_Lacks
           (To_String (Run_Fake (F, "query", "drift").Output), Beta,
            "beta is clean after reseating");
      end;
   end Reseat_Rebuilds_A_Renamed_Node_From_Its_Own_Body;

   procedure Reenumeration_Claims_New_Files_Without_Touching_Prose
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Make_Project (F);
      Build_Namespace (F);
      Add_Gamma (F, 21, 23);
      Commit_All (F, "adds");
      Assert_Contains
        (To_String (Run_Fake (F, "query", "drift").Output),
         "3 new paths already match a manifest pattern",
         "drift sees the adds");

      Ignore (Run_Fake (F, "build-lists", "--reenumerate"));
      Assert
        (Lines (Read_File (Work (F) & "/lists/003.txt")).Length = 23,
         "gamma lists 23 files");

      Write_Work_File (F, "g.md", Full_Prose (F, Gamma));
      Assert_Exit
        (Rewrite (F, Gamma, Work (F) & "/g.md", Work (F) & "/lists/003.txt"),
         0, "write-node");
      Assert_Equal
        (Trim
           (To_String
              (Run_Fake (F, "query", "sources", Gamma, "--count").Output)),
         "23", "gamma covers 23 files");
   end Reenumeration_Claims_New_Files_Without_Touching_Prose;

   procedure A_Diverged_Line_Removing_A_Module_Writes_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Make_Project (F);
      Build_Namespace (F);
      declare
         Fork : constant String := Git_Output (F, "rev-parse", "HEAD");
      begin
         Write_Repo_File
           (F, "mod-alpha/src/main/java/alpha01.java",
            "class alpha01 { int v = 2; }" & LF);
         Commit_All (F, "mainline");
         Build_Namespace (F);

         Ignore (Git (F, "reset", "--hard", "-q", Fork));
         Ignore (Git (F, "rm", "-rq", "mod-gamma"));
         Commit_All (F, "line-drops-gamma");
      end;

      declare
         R : constant Result := Run_Fake (F, "query", "drift");
         O : constant String := To_String (R.Output);
      begin
         Assert_Exit (R, 0, "drift");
         Assert_Contains (O, "is not an ancestor of HEAD", "diverged");
         Assert_Contains (O, Gamma & HT & "20 of its files are gone", "gamma");
      end;

      Ignore (Run_Fake (F, "build-lists", "--reenumerate"));
      Assert
        (not Exists (Work (F) & "/lists/003.txt")
         or else Read_File (Work (F) & "/lists/003.txt") = "",
         "gamma's list is empty");

      declare
         R : constant Result :=
           Run_Fake
             (F, "write-node", "--title", Gamma, "--summary", "x", "--paths",
              Work (F) & "/lists/003.txt", "--body", Work (F) & "/b-003.md");
      begin
         Assert_Exit (R, 1, "write-node with an empty list");
         Assert_Contains (Both (R), "empty path list", "says why");
      end;

      --  The node, and the hand-written notes it holds, are still there.
      Assert_Contains
        (Read_File
           (Vault (F) & "/synapse/" & Repo_Name (F) & "/" & Gamma & ".md"),
         "## Notes", "the node is untouched");

      declare
         R : constant Result := Run_Fake (F, "push-nodes", "003");
      begin
         Assert_Exit (R, 1, "push-nodes");
         Assert
           (Contains (Both (R), "003" & HT & "SKIP (no list/title)")
            or else Contains (Both (R), "003" & HT & "FAILED"),
            "the node is skipped or fails:" & LF & Both (R));
      end;
   end A_Diverged_Line_Removing_A_Module_Writes_Nothing;

   procedure Rebuild_And_Write_Back (F : Fixture; Number : String) is
      Title : constant String := Title_Of (F, Number);
   begin
      Write_Work_File (F, "r-" & Number & ".md", Full_Prose (F, Title));
      Ignore
        (Rewrite
           (F, Title, Work (F) & "/r-" & Number & ".md",
            Work (F) & "/lists/" & Number & ".txt"));
   end Rebuild_And_Write_Back;

   procedure The_Loop_Closes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Make_Project (F);
      Build_Namespace (F);

      Write_Repo_File
        (F, "mod-alpha/src/main/java/alpha01.java",
         "class alpha01 { int v = 99; }" & LF);
      Rename_Beta (F);
      Add_Gamma (F, 21, 21);
      Commit_All (F, "mixed");
      Assert
        (To_String (Run_Fake (F, "query", "drift").Output) /= "",
         "there is drift to repair");

      Ignore (Run_Fake (F, "build-lists", "--reenumerate"));
      Rebuild_And_Write_Back (F, "001");
      Rebuild_And_Write_Back (F, "002");
      Rebuild_And_Write_Back (F, "003");
      Ignore (Run_Fake (F, "build-index"));
      Ignore (Run_Fake (F, "build-project-index"));

      declare
         Drift : constant Result := Run_Fake (F, "query", "drift");
         Stale : constant Result := Run_Fake (F, "query", "stale");
      begin
         Assert_Exit (Drift, 0, "drift");
         Assert_Equal (To_String (Drift.Output), "", "drift is silent");
         Assert_Exit (Stale, 0, "stale");
         Assert_Equal (To_String (Stale.Output), "", "stale is silent");
      end;
   end The_Loop_Closes;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: rebuild and drift");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Fresh_Namespace_Has_No_Drift'Access,
         "a freshly built namespace has no drift");
      Register_Routine
        (T, Mixed_Drift_Is_Classified_Per_Node'Access,
         "mixed drift is classified per node, and the ratios are measurable");
      Register_Routine
        (T, Reseat_Rebuilds_A_Renamed_Node_From_Its_Own_Body'Access,
         "reseat: a rename-only node is rebuilt from its own body");
      Register_Routine
        (T, Reenumeration_Claims_New_Files_Without_Touching_Prose'Access,
         "re-enumeration claims new files without touching prose");
      Register_Routine
        (T, A_Diverged_Line_Removing_A_Module_Writes_Nothing'Access,
         "a diverged line that removes a module leaves an empty list");
      Register_Routine
        (T, The_Loop_Closes'Access,
         "the loop closes: rebuilding every flagged node silences drift");
   end Register_Tests;

end Acceptance.Rebuild_Diff_Tests;
