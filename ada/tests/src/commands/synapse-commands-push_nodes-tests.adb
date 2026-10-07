with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Push_Nodes.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Remote : constant String := "https://example.com/o/widget.git";

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Note (Dir : Scratch; File : String) return String is
     (Synapse.Adapters.File_Bytes.Read
        (Path (Dir, "vault/synapse/widget@main/" & File), 1_000_000));

   procedure Setup (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      F.Clock.Now :=
        Ada.Strings.Unbounded.To_Unbounded_String
          ("2026-09-07T14:32:05+02:00");
      Put_Schema
        (Dir, "graph-node/v1",
         Synapse.Adapters.File_Bytes.Read
           ("../../packages/synapse/schema/graph-node/v1.yaml", 100_000));
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      F.Vars.Set ("SYNAPSE_DISABLE_SYMBOL_CACHE", "1");
      Put_File (Dir, "README.md", "hello" & LF);
      Put_File (Dir, "src/a.ext", "a" & LF);
      Commit_All (Dir);
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", Repo (Dir));
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", Remote);
   end Setup;

   procedure Work (Dir : Scratch; Name, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path (Dir, "work/" & Name)));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work/" & Name), Text);
   end Work;

   --  Node NN: a title, one path and a body with a summary.
   procedure Stage (Dir : Scratch; NN, Title, Source : String) is
   begin
      Work (Dir, "lists/" & NN & ".title", Title & LF);
      Work (Dir, "lists/" & NN & ".txt", Source & LF);
      Work
        (Dir, "b-" & NN & ".md",
         "---" & LF & "summary: Node " & NN & " in one line." & LF & "---" &
         LF & LF & "## Summary" & LF & "Node " & NN & "." & LF & LF &
         "## Crux" & LF & "<!-- crux: none -->" & LF);
   end Stage;

   procedure Push_Writes_Every_Node_That_Has_A_List_And_A_Body
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Stage (Dir, "001", "Node One", "README.md");
      Stage (Dir, "002", "Node Two", "src/a.ext");
      Assert (Run (Env (F), Args) = 0, "success: " & F.Console.Err_Text);
      Assert
        (Has
           (F.Console.Out_Text,
            "001" & HT & "Node One.md" & HT & "1 files" & HT),
         "one: " & F.Console.Out_Text);
      Assert
        (Has
           (F.Console.Out_Text,
            "002" & HT & "Node Two.md" & HT & "1 files" & HT),
         "two");
      Assert
        (Has
           (Note (Dir, "Node One.md"),
            "summary: ""Node 001 in one line.""" & LF),
         "its summary");
      Assert
        (Has (Note (Dir, "Node Two.md"), "- `src/a.ext`" & LF), "its sources");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_Writes_Every_Node_That_Has_A_List_And_A_Body;

   procedure Push_Takes_The_Summary_From_The_Frontmatter_And_Not_The_Prose
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Stage (Dir, "001", "Node One", "README.md");
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (not Has
           (Note (Dir, "Node One.md"),
            "summary: Node 001 in one line." & LF & "---" & LF & LF &
            "## Summary"),
         "frontmatter is not repeated in the body");
      Assert
        (Has
           (Note (Dir, "Node One.md"),
            "<!-- synapse:generated:start -->" & LF & LF & "## Summary" & LF &
            "Node 001." & LF),
         "the prose follows the fence: " & Note (Dir, "Node One.md"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_Takes_The_Summary_From_The_Frontmatter_And_Not_The_Prose;

   procedure Push_With_Numbers_Restricts_The_Push (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Stage (Dir, "001", "Node One", "README.md");
      Stage (Dir, "002", "Node Two", "src/a.ext");
      Assert (Run (Env (F), Args ("002")) = 0, "success");
      Assert
        (not Ada.Directories.Exists
           (Path (Dir, "vault/synapse/widget@main/Node One.md")),
         "one left alone");
      Assert
        (Ada.Directories.Exists
           (Path (Dir, "vault/synapse/widget@main/Node Two.md")),
         "two written");
      Assert (not Has (F.Console.Out_Text, "001"), "one not reported");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_With_Numbers_Restricts_The_Push;

   procedure Push_Skips_A_Node_With_A_List_And_No_Body
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Stage (Dir, "001", "Node One", "README.md");
      Stage (Dir, "002", "Node Two", "src/a.ext");
      Ada.Directories.Delete_File (Path (Dir, "work/b-002.md"));
      Assert (Run (Env (F), Args) = 0, "the other pushes");
      Assert
        (Has (F.Console.Out_Text, "002" & HT & "SKIP (no body)" & LF),
         "skipped: " & F.Console.Out_Text);
      Assert
        (not Ada.Directories.Exists
           (Path (Dir, "vault/synapse/widget@main/Node Two.md")),
         "not written empty");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_Skips_A_Node_With_A_List_And_No_Body;

   procedure Push_Skips_A_Body_With_No_List_Or_Title_Or_An_Empty_List
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Stage (Dir, "001", "Node One", "README.md");
      Stage (Dir, "002", "Node Two", "src/a.ext");
      Stage (Dir, "003", "Node Three", "README.md");
      Stage (Dir, "004", "Node Four", "README.md");
      Ada.Directories.Delete_File (Path (Dir, "work/lists/002.txt"));
      Ada.Directories.Delete_File (Path (Dir, "work/lists/003.title"));
      Work (Dir, "lists/004.txt", "");
      Assert (Run (Env (F), Args) = 0, "the first pushes");
      Assert
        (Has (F.Console.Out_Text, "002" & HT & "SKIP (no list/title)" & LF),
         "no list");
      Assert
        (Has (F.Console.Out_Text, "003" & HT & "SKIP (no list/title)" & LF),
         "no title");
      Assert
        (Has (F.Console.Out_Text, "004" & HT & "SKIP (no list/title)" & LF),
         "empty list");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_Skips_A_Body_With_No_List_Or_Title_Or_An_Empty_List;

   procedure Push_Fails_A_Body_With_No_Summary (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Stage (Dir, "001", "Node One", "README.md");
      Work
        (Dir, "b-001.md",
         "---" & LF & "title: x" & LF & "---" & LF & LF & "body" & LF);
      Assert (Run (Env (F), Args) = 1, "failure");
      Assert
        (Has
           (F.Console.Out_Text,
            "001" & HT & "FAILED (no `summary:` frontmatter in b-001.md)" &
            LF),
         "named: " & F.Console.Out_Text);
      Assert
        (Has (F.Console.Err_Text, "synapse-push-nodes: 1 node(s) failed" & LF),
         "counted: " & F.Console.Err_Text);
      F.Console.Clear;
      Work
        (Dir, "b-001.md",
         "---" & LF & "summary:" & LF & "---" & LF & LF & "body" & LF);
      Assert (Run (Env (F), Args) = 1, "an empty summary is none");
      Assert
        (Has
           (F.Console.Out_Text,
            "FAILED (no `summary:` frontmatter in b-001.md)"),
         "named: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_Fails_A_Body_With_No_Summary;

   procedure Push_Goes_On_After_A_Node_That_Fails (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Stage (Dir, "001", "Node One", "README.md");
      Stage (Dir, "002", "Node Two", "src/a.ext");
      Work
        (Dir, "b-001.md",
         "---" & LF & "summary: s" & LF & "---" & LF & LF & "## Crux" & LF &
         "<!-- crux: nope.ext 1-2 -->" & LF);
      Assert (Run (Env (F), Args) = 1, "one failed");
      Assert
        (Has (F.Console.Out_Text, "001" & HT & "FAILED" & LF), "reported");
      Assert
        (Has (F.Console.Out_Text, "002" & HT & "Node Two.md"),
         "the other pushed: " & F.Console.Out_Text);
      Assert
        (Ada.Directories.Exists
           (Path (Dir, "vault/synapse/widget@main/Node Two.md")),
         "and written");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_Goes_On_After_A_Node_That_Fails;

   procedure Push_With_Nothing_To_Push_Fails (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args) = 1, "no lists directory");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-push-nodes: no lists/ in " & Path (Dir, "work") &
            " -- run `synapse build-lists` first" & LF),
         "named: " & F.Console.Err_Text);
      F.Console.Clear;
      Ada.Directories.Create_Path (Path (Dir, "work/lists"));
      Assert (Run (Env (F), Args) = 1, "an empty directory");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-push-nodes: nothing to push (no lists/NN.title or b-NN.md in " &
            Path (Dir, "work") & ")" & LF),
         "empty: " & F.Console.Err_Text);
      F.Console.Clear;
      Stage (Dir, "001", "Node One", "README.md");
      Ada.Directories.Delete_File (Path (Dir, "work/b-001.md"));
      Assert (Run (Env (F), Args) = 1, "only skips");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-push-nodes: nothing to push (no node had both a list and a body)" &
            LF),
         "only skips: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_With_Nothing_To_Push_Fails;

   procedure Push_Finds_Nodes_By_Three_Digit_Names_Only
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Stage (Dir, "001", "Node One", "README.md");
      Work (Dir, "lists/1.title", "x" & LF);
      Work (Dir, "b-1000.md", "x");
      Work (Dir, "lists/abc.title", "x" & LF);
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (F.Console.Out_Text
           (F.Console.Out_Text'First .. F.Console.Out_Text'First + 3) =
         "001" & HT
         and then Ada.Strings.Fixed.Count (F.Console.Out_Text, "" & LF) = 1,
         "only the one: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_Finds_Nodes_By_Three_Digit_Names_Only;

   procedure Push_Cuts_The_Trailing_Line_Feeds_Off_A_Title
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Stage (Dir, "001", "Node One", "README.md");
      Work (Dir, "lists/001.title", "Node One" & LF & LF & LF);
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (Ada.Directories.Exists
           (Path (Dir, "vault/synapse/widget@main/Node One.md")),
         "named by the title alone");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_Cuts_The_Trailing_Line_Feeds_Off_A_Title;

   procedure Push_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown flag");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("-h")) = 0, "help");
      Assert
        (Has (F.Console.Err_Text, "usage: synapse push-nodes [NN ...]"),
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Push_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Push_Nodes");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Push_Writes_Every_Node_That_Has_A_List_And_A_Body'Access,
         "Push writes every node that has a list and a body");
      Register_Routine
        (T,
         Push_Takes_The_Summary_From_The_Frontmatter_And_Not_The_Prose'Access,
         "Push takes the summary from the frontmatter and not the prose");
      Register_Routine
        (T, Push_With_Numbers_Restricts_The_Push'Access,
         "Push with numbers restricts the push");
      Register_Routine
        (T, Push_Skips_A_Node_With_A_List_And_No_Body'Access,
         "Push skips a node with a list and no body");
      Register_Routine
        (T, Push_Skips_A_Body_With_No_List_Or_Title_Or_An_Empty_List'Access,
         "Push skips a body with no list or title or an empty list");
      Register_Routine
        (T, Push_Fails_A_Body_With_No_Summary'Access,
         "Push fails a body with no summary");
      Register_Routine
        (T, Push_Goes_On_After_A_Node_That_Fails'Access,
         "Push goes on after a node that fails");
      Register_Routine
        (T, Push_With_Nothing_To_Push_Fails'Access,
         "Push with nothing to push fails");
      Register_Routine
        (T, Push_Finds_Nodes_By_Three_Digit_Names_Only'Access,
         "Push finds nodes by three digit names only");
      Register_Routine
        (T, Push_Cuts_The_Trailing_Line_Feeds_Off_A_Title'Access,
         "Push cuts the trailing line feeds off a title");
      Register_Routine (T, Push_Arguments'Access, "Push arguments");
   end Register_Tests;

end Synapse.Commands.Push_Nodes.Tests;
