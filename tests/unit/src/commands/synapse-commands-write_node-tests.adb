with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.Hashing;
with Synapse.Ports.Extractor;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Write_Node.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Remote : constant String := "https://example.com/o/widget.git";

   Engine_Source : constant String :=
     "pub fn start() void {}" & LF & "pub fn stop() void {}" & LF &
     "const x = 1;" & LF;

   Default_Body : constant String :=
     "## Summary" & LF & "The engine." & LF & LF & "## Crux" & LF &
     "<!-- crux: src/engine.ext 1-2 -->" & LF & LF & "## Links" & LF &
     "- uses [[Other]]" & LF;

   function Node_Path
     (Dir : Scratch; File : String := "Engine core.md") return String is
     (Path (Dir, "vault/synapse/widget@main/" & File));

   function Note
     (Dir : Scratch; File : String := "Engine core.md") return String is
     (Synapse.Adapters.File_Bytes.Read (Node_Path (Dir, File), 1_000_000));

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure Put_Inputs
     (Dir   : Scratch;
      Paths : String := "src/engine.ext" & LF & "README.md" & LF;
      Prose : String := Default_Body)
   is
   begin
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "paths.txt"), Paths);
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "body.md"), Prose);
   end Put_Inputs;

   --  A checkout on `main` with a remote, a vault with the node schema, and
   --  the context pinned to them.
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
      Put_File (Dir, "src/engine.ext", Engine_Source);
      Put_File (Dir, "README.md", "hello" & LF);
      Commit_All (Dir);
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", Repo (Dir));
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", Remote);
      Put_Inputs (Dir);
   end Setup;

   function Write_Args
     (Dir : Scratch; Title : String := "Engine core")
      return Synapse.Commands.Lists.Vector is
     (Args
        ("--title", Title, "--summary", "The engine.", "--paths",
         Path (Dir, "paths.txt"), "--body", Path (Dir, "body.md")));

   procedure Write_Makes_A_Fenced_Node_With_An_Empty_Notes_Section
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Write_Args (Dir)) = 0,
         "success: " & F.Console.Err_Text);
      Assert
        (Has (F.Console.Out_Text, "Engine core.md" & HT & "2 files" & HT)
         and then F.Console.Out_Text (F.Console.Out_Text'Last) = LF,
         "the line: " & F.Console.Out_Text);
      Assert
        (Has (Note (Dir), "built_at: ""2026-09-07 14:32""" & LF),
         "built_at: " & Note (Dir));
      declare
         Text : constant String := Note (Dir);
      begin
         Assert
           (Has
              (Text,
               "schema: graph-node/v1" & LF & "title: ""Engine core""" & LF &
               "summary: ""The engine.""" & LF),
            "frontmatter: " & Text);
         Assert
           (Has (Text, "project: widget" & LF & "branch: main" & LF),
            "project and branch");
         Assert
           (Has
              (Text, "commit: " & Git (Repo (Dir), "rev-parse", "HEAD") & LF),
            "baseline commit");
         Assert (Has (Text, "stale: false" & LF), "fresh");
         Assert
           (Has
              (Text,
               "# Engine core" & LF & "<!-- synapse:generated:start -->" & LF),
            "the fence opens");
         Assert
           (Has
              (Text,
               "<!-- synapse:generated:end -->" & LF & LF & "## Notes" & LF &
               LF),
            "an empty notes section after it");
         Assert
           (Has
              (Text,
               "## Sources" & LF & "- `README.md`" & LF &
               "- `src/engine.ext`" & LF),
            "sources mirror: " & Text);
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Makes_A_Fenced_Node_With_An_Empty_Notes_Section;

   procedure Write_Records_The_Blob_Hash_Of_Every_Source
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "success");
      Assert
        (Has
           (Note (Dir),
            "  - path: README.md" & LF & "    hash: " &
            Synapse.Core.Hashing.Blob_Hash_Hex ("hello" & LF) & LF),
         "the hash: " & Note (Dir));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Records_The_Blob_Hash_Of_Every_Source;

   procedure Write_Gives_One_Digest_Whatever_The_Order_Of_The_Paths
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "ordered");
      declare
         First : constant String := F.Console.Out_Text;
      begin
         F.Console.Clear;
         Put_Inputs
           (Dir,
            "README.md" & LF & LF & "src/engine.ext" & ASCII.CR & LF &
            "README.md" & LF);
         Assert
           (Run (Env (F), Write_Args (Dir)) = 0,
            "shuffled, with a repeat and a blank");
         Assert
           (F.Console.Out_Text = First,
            "the same line: " & F.Console.Out_Text);
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Gives_One_Digest_Whatever_The_Order_Of_The_Paths;

   procedure Write_Expands_The_Crux_Directive_Into_The_Lines_It_Points_At
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "success");
      Assert
        (Has
           (Note (Dir),
            "crux_path: src/engine.ext" & LF & "crux_lines: ""1-2""" & LF),
         "recorded: " & Note (Dir));
      Assert
        (Has
           (Note (Dir),
            "## Crux" & LF & "```" & LF & "pub fn start() void {}" & LF &
            "pub fn stop() void {}" & LF & "```"),
         "the lines, verbatim: " & Note (Dir));
      Assert (not Has (Note (Dir), "<!-- crux:"), "the directive is replaced");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Expands_The_Crux_Directive_Into_The_Lines_It_Points_At;

   procedure Write_Names_The_Fence_Language_When_The_Registry_Knows_The_Extension
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_Config
        (Dir, "synapse-fence-languages.conf", "{"".ext"": ""ext-lang""}");
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "success");
      Assert
        (Has (Note (Dir), "```ext-lang" & LF & "pub fn start()"),
         "fence: " & Note (Dir));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Names_The_Fence_Language_When_The_Registry_Knows_The_Extension;

   procedure Write_Takes_None_As_An_Answer_For_The_Crux
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_Inputs
        (Dir,
         Prose =>
           "## Summary" & LF & "x" & LF & LF & "## Crux" & LF &
           "<!-- crux: none -->" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "success");
      Assert
        (Has (Note (Dir), "_No single span carries this node's logic._"),
         "said so: " & Note (Dir));
      Assert (not Has (Note (Dir), "crux_path:"), "no pointer");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Takes_None_As_An_Answer_For_The_Crux;

   procedure Write_Ignores_A_Directive_Quoted_Outside_The_Crux_Section
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_Inputs
        (Dir,
         Prose =>
           "## Summary" & LF & "write <!-- crux: x 1-2 --> like so" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "success");
      Assert (Has (Note (Dir), "<!-- crux: x 1-2 -->"), "left as prose");
      Assert (not Has (Note (Dir), "crux_path:"), "no pointer");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Ignores_A_Directive_Quoted_Outside_The_Crux_Section;

   procedure Write_Refuses_A_Crux_It_Cannot_Stand_Behind
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_File (Dir, "src/other.ext", "o" & LF);
      Put_Inputs (Dir, Paths => "src/engine.ext" & LF & "src/gone.ext" & LF);
      Assert
        (Run (Env (F), Write_Args (Dir)) = 1, "a listed file that is gone");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: not regular files in " & Repo (Dir) &
            ": src/gone.ext" & LF &
            "  (deleted since enumeration, or a submodule gitlink -- drop them from the list)" &
            LF),
         "named: " & F.Console.Err_Text);
      F.Console.Clear;
      Put_Inputs
        (Dir,
         Prose => "## Crux" & LF & "<!-- crux: src/other.ext 1-1 -->" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "not claimed");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: crux path is not in this node's sources: src/other.ext" &
            LF),
         "claimed: " & F.Console.Err_Text);
      F.Console.Clear;
      Put_Inputs
        (Dir,
         Prose => "## Crux" & LF & "<!-- crux: src/engine.ext 1-99 -->" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "out of range");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: crux range 1-99 outside src/engine.ext (1-3)" &
            LF),
         "range: " & F.Console.Err_Text);
      F.Console.Clear;
      Put_Inputs
        (Dir, Prose => "## Crux" & LF & "<!-- crux: nonsense -->" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "malformed");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: bad crux directive: <!-- crux: nonsense -->" &
            LF &
            "  expected: <!-- crux: path/to/file.ext 412-419 -->  (or 'none')" &
            LF),
         "malformed: " & F.Console.Err_Text);
      F.Console.Clear;
      Put_Inputs
        (Dir,
         Prose => "## Crux" & LF & "<!-- crux: src/gone.ext 1-2 -->" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "not a file");
      Assert (not Ada.Directories.Exists (Node_Path (Dir)), "nothing written");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Refuses_A_Crux_It_Cannot_Stand_Behind;

   procedure Write_Refuses_A_Crux_Longer_Than_Its_Cap
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      declare
         Long : Ada.Strings.Unbounded.Unbounded_String;
      begin
         for I in 1 .. 40 loop
            Ada.Strings.Unbounded.Append (Long, "line" & LF);
         end loop;
         Put_File
           (Dir, "src/long.ext", Ada.Strings.Unbounded.To_String (Long));
         Git (Repo (Dir), "add", "-A");
      end;
      Put_Inputs
        (Dir, Paths => "src/long.ext" & LF,
         Prose => "## Crux" & LF & "<!-- crux: src/long.ext 1-30 -->" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "too long");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: crux range 1-30 is 30 lines; keep it under 20" &
            LF &
            "  a crux is the few lines carrying the decision, not the whole function" &
            LF),
         "says so: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Refuses_A_Crux_Longer_Than_Its_Cap;

   procedure Write_Records_A_Grounding_As_A_Digest_And_Strips_The_Directive
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_Inputs
        (Dir,
         Prose =>
           "## Summary" & LF &
           "It starts. <!-- grounded_in: src/engine.ext 1-2 -->" & LF &
           "More." & LF);
      Assert
        (Run (Env (F), Write_Args (Dir)) = 0,
         "success: " & F.Console.Err_Text);
      declare
         Text : constant String := Note (Dir);
      begin
         Assert
           (Has
              (Text,
               "grounded_in:" & LF & "  - path: src/engine.ext" & LF &
               "    lines: ""1-2""" & LF & "    digest: " &
               Synapse.Core.Hashing.Sha256_Hex
                 ("pub fn start() void {}" & LF & "pub fn stop() void {}" &
                  LF) &
               LF),
            "recorded: " & Text);
         Assert
           (not Has (Text, "<!-- grounded_in"), "stripped from the prose");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Records_A_Grounding_As_A_Digest_And_Strips_The_Directive;

   procedure Write_Refuses_A_Grounding_It_Cannot_Stand_Behind
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_Inputs
        (Dir, Prose => "<!-- grounded_in: src/engine.ext 1-99 -->" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "range");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: grounded_in range 1-99 outside src/engine.ext (1-3)" &
            LF),
         "range: " & F.Console.Err_Text);
      F.Console.Clear;
      Put_Inputs (Dir, Prose => "<!-- grounded_in: nonsense -->" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "malformed");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: bad grounded_in directive: <!-- grounded_in: nonsense -->" &
            LF & "  expected: <!-- grounded_in: path/to/file.ext 10-14 -->" &
            LF),
         "malformed: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Refuses_A_Grounding_It_Cannot_Stand_Behind;

   procedure Write_Keeps_Hand_Written_Notes_When_It_Rewrites
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "first");
      Synapse.Adapters.File_Bytes.Write
        (Node_Path (Dir), Note (Dir) & "my own thought" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "second");
      Assert
        (Has (Note (Dir), "## Notes" & LF & LF & "my own thought" & LF),
         "kept: " & Note (Dir));
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "third");
      Assert
        (Ada.Strings.Fixed.Count (Note (Dir), "my own thought") = 1,
         "kept once, not grown by each write");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Keeps_Hand_Written_Notes_When_It_Rewrites;

   procedure Write_Trims_The_Blank_Lines_After_Hand_Written_Notes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "first");
      Synapse.Adapters.File_Bytes.Write
        (Node_Path (Dir), Note (Dir) & "thought" & LF & LF & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "second");
      declare
         Text : constant String := Note (Dir);
      begin
         Assert
           (Text (Text'Last - 7 .. Text'Last) = "thought" & LF,
            "one line feed after the notes: " & Text);
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Trims_The_Blank_Lines_After_Hand_Written_Notes;

   procedure Write_Refuses_A_Node_With_A_Stray_Marker_Past_The_First
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "first");
      Synapse.Adapters.File_Bytes.Write
        (Node_Path (Dir),
         Note (Dir) & "<!-- synapse:generated:start -->" & LF & "x" & LF &
         "<!-- synapse:generated:end -->" & LF);
      F.Console.Clear;
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "refused");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: Engine core.md already has a stray generated-region marker past its first `<!-- synapse:generated:end -->` -- refusing to write" &
            LF),
         "named: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Refuses_A_Node_With_A_Stray_Marker_Past_The_First;

   procedure Write_Refuses_Another_Repository_S_Namespace
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "remote: ""https://example.com/o/other.git""" & LF &
         "branch: ""main""" & LF & "---" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "a different remote");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: synapse/widget@main/ belongs to a different repo" &
            LF & "  existing remote: https://example.com/o/other.git" & LF &
            "  this repo:       " & Remote & LF &
            "  refusing to overwrite -- rename one of the two repos first" &
            LF),
         "named: " & F.Console.Err_Text);
      F.Console.Clear;
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "remote: """ & Remote & """" & LF & "branch: ""dev""" &
         LF & "---" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "a different branch");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: synapse/widget@main/ records branch 'dev', not 'main'" &
            LF &
            "  the directory name and its branch field disagree -- refusing to write" &
            LF),
         "named: " & F.Console.Err_Text);
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "remote: """ & Remote & """" & LF & "branch: ""main""" &
         LF & "---" & LF);
      F.Console.Clear;
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "the same repository");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Refuses_Another_Repository_S_Namespace;

   procedure Write_Warns_When_The_Title_Had_To_Change
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Write_Args (Dir, "A: b/c")) = 0, "success");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: WARNING title needed sanitizing, so [[A: b/c]] will not resolve" &
            LF &
            "  filename: A_ b_c.md -- reword the title to avoid divergence" &
            LF),
         "warned: " & F.Console.Err_Text);
      Assert
        (Ada.Directories.Exists (Node_Path (Dir, "A_ b_c.md")),
         "the sanitised file");
      Assert
        (Has (Note (Dir, "A_ b_c.md"), "title: ""A: b/c"""),
         "the real title kept");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Warns_When_The_Title_Had_To_Change;

   procedure Write_Notes_Sources_Changed_Since_The_Baseline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "repo/README.md"), "changed" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "success");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: NOTE uncommitted changes in this node's sources: README.md" &
            LF & "  commit: " & Git (Repo (Dir), "rev-parse", "HEAD") &
            " records what was checked out, not a faithful drift baseline" &
            LF),
         "noted: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Notes_Sources_Changed_Since_The_Baseline;

   procedure Write_Names_At_Most_Three_Changed_Sources
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_File (Dir, "s/a.ext", "1" & LF);
      Put_File (Dir, "s/b.ext", "1" & LF);
      Put_File (Dir, "s/c.ext", "1" & LF);
      Put_File (Dir, "s/d.ext", "1" & LF);
      Commit_All (Dir);
      Put_File (Dir, "s/a.ext", "2" & LF);
      Put_File (Dir, "s/b.ext", "2" & LF);
      Put_File (Dir, "s/c.ext", "2" & LF);
      Put_File (Dir, "s/d.ext", "2" & LF);
      Put_Inputs
        (Dir,
         Paths =>
           "s/a.ext" & LF & "s/b.ext" & LF & "s/c.ext" & LF & "s/d.ext" & LF,
         Prose => "## Summary" & LF & "x" & LF);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "success");
      Assert
        (Has
           (F.Console.Err_Text,
            "changes in this node's sources: s/a.ext s/b.ext s/c.ext" & LF),
         "three named: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Names_At_Most_Three_Changed_Sources;

   procedure Write_Leaves_The_Commit_Out_Before_There_Is_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Delete_Tree (Path (Dir, "repo/.git"));
      Git (Repo (Dir), "init", "-q");
      Assert
        (Run (Env (F), Write_Args (Dir)) = 0,
         "success: " & F.Console.Err_Text);
      Assert (not Has (Note (Dir), "commit:"), "no baseline: " & Note (Dir));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Leaves_The_Commit_Out_Before_There_Is_One;

   procedure Write_Keeps_The_Tags_Cache_Current (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "success");
      Assert
        (Ada.Directories.Exists (Path (Dir, "work/_tags_cache.bin")),
         "the cache exists");
      Assert (F.Extractors.Source.Calls <= 1, "at most one batch");
      declare
         Before : constant Natural := F.Extractors.Source.Calls;
      begin
         Assert (Run (Env (F), Write_Args (Dir)) = 0, "again");
         Assert
           (F.Extractors.Source.Calls = Before, "nothing is tagged twice");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Keeps_The_Tags_Cache_Current;

   procedure Write_Leaves_The_Tags_Cache_Alone_When_Told_To
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_DISABLE_SYMBOL_CACHE", "1");
      Assert (Run (Env (F), Write_Args (Dir)) = 0, "success");
      Assert
        (not Ada.Directories.Exists (Path (Dir, "work/_tags_cache.bin")),
         "no cache");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Leaves_The_Tags_Cache_Alone_When_Told_To;

   procedure Write_Needs_Its_Inputs (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args) = 2, "nothing");
      Assert
        (Run
           (Env (F), Args ("--title", "t", "--summary", "s", "--paths", "p")) =
         2,
         "no body");
      Assert (Run (Env (F), Args ("--title")) = 2, "dangling");
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert
        (Run
           (Env (F),
            Args
              ("--title", "t", "--summary", "s", "--paths", Path (Dir, "none"),
               "--body", Path (Dir, "body.md"))) =
         1,
         "no path list");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: empty path list: " & Path (Dir, "none") & LF),
         "says so");
      F.Console.Clear;
      Assert
        (Run
           (Env (F),
            Args
              ("--title", "t", "--summary", "s", "--paths",
              Path (Dir, "paths.txt"), "--body", Path (Dir, "none"))) =
         1,
         "no body");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-write-node: no body file: " & Path (Dir, "none") & LF),
         "says so");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Has
           (F.Console.Err_Text,
            "usage: synapse write-node --title <t> --summary <s> --paths <file> --body <file>"),
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Needs_Its_Inputs;

   procedure Write_Needs_A_Readable_Fence_Registry
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_Config (Dir, "synapse-fence-languages.conf", "nonsense");
      Assert (Run (Env (F), Write_Args (Dir)) = 1, "bad registry");
      Assert
        (F.Console.Err_Text =
         "synapse-write-node: cannot read the fence-languages registry" & LF,
         "says so: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Needs_A_Readable_Fence_Registry;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Write_Node");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Write_Makes_A_Fenced_Node_With_An_Empty_Notes_Section'Access,
         "Write makes a fenced node with an empty notes section");
      Register_Routine
        (T, Write_Records_The_Blob_Hash_Of_Every_Source'Access,
         "Write records the blob hash of every source");
      Register_Routine
        (T, Write_Gives_One_Digest_Whatever_The_Order_Of_The_Paths'Access,
         "Write gives one digest whatever the order of the paths");
      Register_Routine
        (T,
         Write_Expands_The_Crux_Directive_Into_The_Lines_It_Points_At'Access,
         "Write expands the crux directive into the lines it points at");
      Register_Routine
        (T,
         Write_Names_The_Fence_Language_When_The_Registry_Knows_The_Extension'
           Access,
         "Write names the fence language when the registry knows the extension");
      Register_Routine
        (T, Write_Takes_None_As_An_Answer_For_The_Crux'Access,
         "Write takes none as an answer for the crux");
      Register_Routine
        (T, Write_Ignores_A_Directive_Quoted_Outside_The_Crux_Section'Access,
         "Write ignores a directive quoted outside the crux section");
      Register_Routine
        (T, Write_Refuses_A_Crux_It_Cannot_Stand_Behind'Access,
         "Write refuses a crux it cannot stand behind");
      Register_Routine
        (T, Write_Refuses_A_Crux_Longer_Than_Its_Cap'Access,
         "Write refuses a crux longer than its cap");
      Register_Routine
        (T,
         Write_Records_A_Grounding_As_A_Digest_And_Strips_The_Directive'Access,
         "Write records a grounding as a digest and strips the directive");
      Register_Routine
        (T, Write_Refuses_A_Grounding_It_Cannot_Stand_Behind'Access,
         "Write refuses a grounding it cannot stand behind");
      Register_Routine
        (T, Write_Keeps_Hand_Written_Notes_When_It_Rewrites'Access,
         "Write keeps hand written notes when it rewrites");
      Register_Routine
        (T, Write_Trims_The_Blank_Lines_After_Hand_Written_Notes'Access,
         "Write trims the blank lines after hand written notes");
      Register_Routine
        (T, Write_Refuses_A_Node_With_A_Stray_Marker_Past_The_First'Access,
         "Write refuses a node with a stray marker past the first");
      Register_Routine
        (T, Write_Refuses_Another_Repository_S_Namespace'Access,
         "Write refuses another repository's namespace");
      Register_Routine
        (T, Write_Warns_When_The_Title_Had_To_Change'Access,
         "Write warns when the title had to change");
      Register_Routine
        (T, Write_Notes_Sources_Changed_Since_The_Baseline'Access,
         "Write notes sources changed since the baseline");
      Register_Routine
        (T, Write_Names_At_Most_Three_Changed_Sources'Access,
         "Write names at most three changed sources");
      Register_Routine
        (T, Write_Leaves_The_Commit_Out_Before_There_Is_One'Access,
         "Write leaves the commit out before there is one");
      Register_Routine
        (T, Write_Keeps_The_Tags_Cache_Current'Access,
         "Write keeps the tags cache current");
      Register_Routine
        (T, Write_Leaves_The_Tags_Cache_Alone_When_Told_To'Access,
         "Write leaves the tags cache alone when told to");
      Register_Routine
        (T, Write_Needs_Its_Inputs'Access, "Write needs its inputs");
      Register_Routine
        (T, Write_Needs_A_Readable_Fence_Registry'Access,
         "Write needs a readable fence registry");
   end Register_Tests;

end Synapse.Commands.Write_Node.Tests;
