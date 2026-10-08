with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Acceptance.Fixtures;
with Synapse.Core.Text_Lists;

package body Acceptance.Pipeline_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Java  : constant String := "Java " & Dash & " the application";
   Docs  : constant String := "Docs " & Dash & " the documentation";
   Ocaml : constant String := "OCaml " & Dash & " the library";

   procedure Set_Up_Tree (F : in out Fixture) is
   begin
      Make_Repo (F);
      Write_Repo_File
        (F, "src/main/java/com/example/App.java", "class App {}" & LF);
      Write_Repo_File
        (F, "src/main/java/com/example/Util.java", "class Util {}" & LF);
      Write_Repo_File (F, "lib/core.ml", "let f x = x" & LF);
      Write_Repo_File (F, "docs/guide.md", "# Guide" & LF);
      Write_Repo_File (F, "docs/notes.md", "# Notes" & LF);
      Write_Repo_File (F, "assets/logo.png", "PNG" & LF);
      Write_Repo_File (F, "leftover.txt", "orphan" & LF);
      Commit_All (F, "tree");
      Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
      Use_Schema_Content_Root (F);
   end Set_Up_Tree;

   --  The four real steps in sequence. The index is written straight to the
   --  work directory, where every reader already looks.
   procedure Run_Pipeline (F : Fixture) is
   begin
      Write_Work_File
        (F, "manifest.tsv",
         Java & ASCII.HT & "^src/" & ASCII.HT & LF & Docs & ASCII.HT &
         "^docs/" & ASCII.HT & LF & Ocaml & ASCII.HT & "^lib/" & ASCII.HT &
         LF);
      Assert_Exit (Run_Fake (F, "build-lists"), 0, "build-lists");

      --  Each authored body carries its own one-line summary in frontmatter;
      --  the writer strips it and it becomes the node's `summary` field,
      --  which the index reads back.
      Write_Work_File
        (F, "b-001.md",
         "---" & LF & "summary: The java application." & LF & "---" & LF & LF &
         "## Summary" & LF & "The java application." & LF & LF & "## Links" &
         LF & "- uses [[" & Docs & "]]" & LF);
      Write_Work_File
        (F, "b-002.md",
         "---" & LF & "summary: The documentation." & LF & "---" & LF & LF &
         "## Summary" & LF & "The documentation." & LF);
      Write_Work_File
        (F, "b-003.md",
         "---" & LF & "summary: The ocaml library." & LF & "---" & LF & LF &
         "## Summary" & LF & "The ocaml library." & LF);

      Assert_Exit (Run_Fake (F, "push-nodes"), 0, "push-nodes");
      Assert_Exit (Run_Fake (F, "build-index"), 0, "build-index");
      Assert_Exit
        (Run_Fake (F, "build-project-index"), 0, "build-project-index");
   end Run_Pipeline;

   function Ns_Dir (F : Fixture) return String is
     (Vault (F) & "/synapse/" & Repo_Name (F));

   procedure Four_Steps_Make_A_Consistent_Namespace
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up_Tree (F);
      Run_Pipeline (F);
      declare
         Dir : constant String := Ns_Dir (F);
      begin
         Assert (Exists (Dir & "/" & Java & ".md"), "missing the java node");
         Assert (Exists (Dir & "/" & Docs & ".md"), "missing the docs node");
         Assert (Exists (Dir & "/" & Ocaml & ".md"), "missing the ocaml node");
         Assert (Exists (Dir & "/Index.md"), "missing Index.md");
         Assert (Exists (Work (F) & "/_index.bin"), "no _index.bin");

         --  The binary file was dropped at enumeration, and the one text file
         --  no node claimed is in unassigned.txt and not lost.
         Assert_Lacks
           (Read_File (Work (F) & "/all.txt"), "logo.png", "all.txt");
         Assert
           (Has_Line
              (Read_File (Work (F) & "/unassigned.txt"), "leftover.txt"),
            "leftover.txt is unassigned");

         declare
            Index : constant String := Work (F) & "/_index.bin";
            R5    : constant Result :=
              Run_Fake (F, "index", "unassigned", "--file", Index);
            R6    : constant Result :=
              Run_Fake (F, "index", "nodes", "--file", Index);
         begin
            Assert_Contains
              (To_String (R5.Output), "leftover.txt", "index unassigned");
            --  Every node in the index points at a file that exists.
            for Node of Lines (To_String (R6.Output)) loop
               if Length (Node) > 0 then
                  Assert
                    (Exists (Dir & "/" & To_String (Node)),
                     "index names a missing node " & To_String (Node));
               end if;
            end loop;
         end;
      end;
   end Four_Steps_Make_A_Consistent_Namespace;

   --  Every `[[target]]` in the text, in order.
   function Wikilinks (Text : String) return Synapse.Core.Text_Lists.Vector is
      Result : Synapse.Core.Text_Lists.Vector;
      Pos    : Natural := Text'First;
   begin
      while Pos < Text'Last loop
         declare
            Start : constant Natural :=
              Ada.Strings.Fixed.Index (Text (Pos .. Text'Last), "[[");
         begin
            exit when Start = 0;
            declare
               Stop : constant Natural :=
                 Ada.Strings.Fixed.Index (Text (Start .. Text'Last), "]]");
            begin
               exit when Stop = 0;
               Result.Append
                 (To_Unbounded_String (Text (Start + 2 .. Stop - 1)));
               Pos := Stop + 2;
            end;
         end;
      end loop;
      return Result;
   end Wikilinks;

   procedure Every_Wikilink_Resolves_And_Every_Node_Is_Indexed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up_Tree (F);
      Run_Pipeline (F);
      declare
         Dir   : constant String                         := Ns_Dir (F);
         Names : constant Synapse.Core.Text_Lists.Vector :=
           Files_In (Dir, ".md");
         Index : constant String := Read_File (Dir & "/Index.md");
      begin
         --  A broken wikilink is a valid link to a not-yet-existing note, so
         --  it fails silently in a viewer: only this check catches it.
         for Name of Names loop
            for Target of Wikilinks (Read_File (Dir & "/" & To_String (Name)))
            loop
               Assert
                 (Exists (Dir & "/" & To_String (Target) & ".md"),
                  "broken wikilink " & To_String (Target));
            end loop;
         end loop;

         --  And the reverse: a node missing from the index is invisible to a
         --  reader.
         for Name of Names loop
            if To_String (Name) /= "Index.md" then
               declare
                  Title : constant String :=
                    To_String (Name) (1 .. Length (Name) - 3);
               begin
                  Assert_Contains (Index, "[[" & Title & "]]", "Index.md");
               end;
            end if;
         end loop;
      end;
   end Every_Wikilink_Resolves_And_Every_Node_Is_Indexed;

   procedure Query_Reads_Back_What_The_Pipeline_Wrote
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up_Tree (F);
      Run_Pipeline (F);

      --  body prints the prose only: no frontmatter, no ## Notes.
      declare
         R : constant Result := Run_Fake (F, "query", "body", Java, "--full");
      begin
         Assert_Exit (R, 0, "query body");
         Assert_Contains
           (To_String (R.Output), "The java application.", "prose");
         Assert_Lacks
           (To_String (R.Output), "sources_digest", "no frontmatter");
         Assert_Lacks (To_String (R.Output), "## Notes", "no notes");
      end;

      --  Asserted against the list the node was built from, so the two
      --  cannot drift: the ^src/ pattern also picks up the helper's
      --  src/foo.aa.
      declare
         R        : constant Result  :=
           Run_Fake (F, "query", "sources", Java, "--count");
         Expected : constant Natural :=
           Natural (Lines (Read_File (Work (F) & "/lists/001.txt")).Length);
      begin
         Assert_Exit (R, 0, "query sources --count");
         Assert_Equal
           (Trim (To_String (R.Output)),
            Ada.Strings.Fixed.Trim
              (Natural'Image (Expected), Ada.Strings.Left),
            "count matches the list");
         Assert (Expected = 3, "three files under ^src/");
      end;

      declare
         R : constant Result :=
           Run_Fake (F, "query", "sources", Docs, "--modules");
      begin
         Assert_Exit (R, 0, "query sources --modules");
         Assert_Contains (To_String (R.Output), "docs", "modules");
      end;

      declare
         R : constant Result :=
           Run_Fake (F, "query", "field", Ocaml, "project");
      begin
         Assert_Exit (R, 0, "query field");
         Assert_Equal (Trim (To_String (R.Output)), Ns_Repo (F), "project");
      end;
   end Query_Reads_Back_What_The_Pipeline_Wrote;

   procedure A_Fresh_Namespace_Verifies_Clean_And_Detects_An_Edit
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up_Tree (F);
      Run_Pipeline (F);

      --  Silence means clean: the digests the writer computed must satisfy
      --  the verifier's independent recomputation of the same definition.
      declare
         R : constant Result := Run_Fake (F, "query", "stale");
      begin
         Assert_Exit (R, 0, "query stale, fresh");
         Assert_Equal (Trim (To_String (R.Output)), "", "nothing is stale");
      end;

      Write_Repo_File
        (F, "src/main/java/com/example/App.java", "class App { int x; }" & LF);
      declare
         R : constant Result := Run_Fake (F, "query", "stale");
         O : constant String := To_String (R.Output);
      begin
         Assert_Exit (R, 0, "query stale, edited");
         Assert_Contains (O, Java & ASCII.HT & "content changed", "the edit");
         --  Only the node covering that file may be flagged.
         Assert_Lacks (O, "OCaml", "ocaml node");
         Assert_Lacks (O, "Docs", "docs node");
      end;
   end A_Fresh_Namespace_Verifies_Clean_And_Detects_An_Edit;

   procedure A_Deleted_Source_Is_Reported_By_Name (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up_Tree (F);
      Run_Pipeline (F);
      Delete_File (Repo (F) & "/lib/core.ml");
      declare
         R : constant Result := Run_Fake (F, "query", "stale");
      begin
         Assert_Exit (R, 0, "query stale");
         Assert_Contains
           (To_String (R.Output),
            Ocaml & ASCII.HT & "source files gone: lib/core.ml",
            "the deleted file is named");
      end;
   end A_Deleted_Source_Is_Reported_By_Name;

   function Digest_Line (Body_Text : String) return String is
   begin
      for Item of Lines (Body_Text) loop
         declare
            Line : constant String := To_String (Item);
         begin
            if Line'Length >= 16
              and then Line (Line'First .. Line'First + 15) =
                "sources_digest: "
            then
               return Line;
            end if;
         end;
      end loop;
      return "";
   end Digest_Line;

   procedure Running_The_Pipeline_Again_Changes_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up_Tree (F);
      Run_Pipeline (F);
      declare
         Node  : constant String := Ns_Dir (F) & "/" & Java & ".md";
         First : constant String := Digest_Line (Read_File (Node));
      begin
         Run_Pipeline (F);
         Assert_Equal (Digest_Line (Read_File (Node)), First, "digest");
         Assert (First /= "", "the node has a digest");
      end;

      --  The node count does not drift, and the namespace still verifies.
      declare
         Count : Natural := 0;
      begin
         for Name of Files_In (Ns_Dir (F), ".md") loop
            if To_String (Name) /= "Index.md" then
               Count := Count + 1;
            end if;
         end loop;
         Assert (Count = 3, "three nodes, found" & Natural'Image (Count));
      end;
      declare
         R : constant Result := Run_Fake (F, "query", "stale");
      begin
         Assert_Exit (R, 0, "query stale");
         Assert_Equal (Trim (To_String (R.Output)), "", "nothing is stale");
      end;
   end Running_The_Pipeline_Again_Changes_Nothing;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: the build pipeline");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Four_Steps_Make_A_Consistent_Namespace'Access,
         "the four steps produce a complete, self-consistent namespace");
      Register_Routine
        (T, Every_Wikilink_Resolves_And_Every_Node_Is_Indexed'Access,
         "every wikilink resolves, and every node is listed in Index.md");
      Register_Routine
        (T, Query_Reads_Back_What_The_Pipeline_Wrote'Access,
         "query reads back what the pipeline wrote");
      Register_Routine
        (T, A_Fresh_Namespace_Verifies_Clean_And_Detects_An_Edit'Access,
         "a fresh namespace verifies clean, and detects a real edit");
      Register_Routine
        (T, A_Deleted_Source_Is_Reported_By_Name'Access,
         "a deleted source is reported by name");
      Register_Routine
        (T, Running_The_Pipeline_Again_Changes_Nothing'Access,
         "re-running the pipeline is idempotent");
   end Register_Tests;

end Acceptance.Pipeline_Tests;
