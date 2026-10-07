with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Commands.Index;
with Synapse.Commands.Project_Index;
with Synapse.Commands.Push_Nodes;
with Synapse.Core.Graph_Model;
with Synapse.Core.Tag_Payload;
with Synapse.Ports.Extractor;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Query.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   package Port renames Synapse.Ports.Extractor;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Remote : constant String := "https://example.com/o/widget.git";

   Engine_Source : constant String :=
     "pub fn start() void {}" & LF & "pub fn stop() void {}" & LF &
     "const x = 1;" & LF;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure Work (Dir : Scratch; Name, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path (Dir, "work/" & Name)));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work/" & Name), Text);
   end Work;

   function Node_Path (Dir : Scratch; File : String) return String is
     (Path (Dir, "vault/synapse/widget@main/" & File));

   function With_Ref (Name : String) return Port.Outcome is
      Tags : Synapse.Core.Tag_Payload.Tag_Vectors.Vector;
   begin
      Tags.Append
        (Synapse.Core.Graph_Model.Tag'
           (Name       => To_Unbounded_String (Name),
            Kind       => To_Unbounded_String ("call"),
            Which      => Synapse.Core.Graph_Model.Ref, Line => 1,
            Expression => To_Unbounded_String (Name & " ()")));
      return (Kind => Port.With_Tags, Tags => Tags);
   end With_Ref;

   --  Two nodes written by `push-nodes` over a checkout of three files, an
   --  index, and a vault that agrees with them. Node one has a grounding, a
   --  crux and a link to a node that is not there.
   procedure Setup (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      F.Clock.Now := To_Unbounded_String ("2026-09-07T14:32:05+02:00");
      Put_Schema
        (Dir, "graph-node/v1",
         Synapse.Adapters.File_Bytes.Read
           ("../../packages/synapse/schema/graph-node/v1.yaml", 100_000));
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      Put_File (Dir, "src/engine.ext", Engine_Source);
      Put_File (Dir, "src/render.ext", "paint" & LF);
      Put_File (Dir, "README.md", "hello" & LF);
      Commit_All (Dir);
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", Repo (Dir));
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", Remote);
      F.Extractors.Source.Script ("src/render.ext", With_Ref ("start"));
      Work (Dir, "lists/001.title", "Engine core" & LF);
      Work (Dir, "lists/001.txt", "src/engine.ext" & LF & "README.md" & LF);
      Work (Dir, "lists/002.title", "Render" & LF);
      Work (Dir, "lists/002.txt", "src/render.ext" & LF);
      Work (Dir, "unassigned.txt", "");
      Work
        (Dir, "b-001.md",
         "---" & LF & "summary: The engine." & LF & "---" & LF & LF &
         "## Summary" & LF &
         "It does <!-- grounded_in: src/engine.ext 1-2 --> things." & LF & LF &
         "## Crux" & LF & "<!-- crux: src/engine.ext 1-2 -->" & LF & LF &
         "## Links" & LF & "- uses [[Render]]" & LF & "- part_of [[Missing]]" &
         LF);
      Work
        (Dir, "b-002.md",
         "---" & LF & "summary: Render." & LF & "---" & LF & LF &
         "## Summary" & LF & "Paints." & LF & LF & "## Crux" & LF &
         "<!-- crux: none -->" & LF & LF & "## Links" & LF &
         "- needs [[Engine core]]" & LF);
      Assert
        (Synapse.Commands.Push_Nodes.Run (Env (F), Args) = 0,
         "pushed: " & F.Console.Err_Text);
      Assert
        (Synapse.Commands.Project_Index.Run (Env (F), Args) = 0,
         "indexed nodes: " & F.Console.Err_Text);
      Assert
        (Synapse.Commands.Index.Run_Build_Index (Env (F), Args) = 0,
         "indexed paths: " & F.Console.Err_Text);
      F.Console.Clear;
   end Setup;

   procedure Commit_Change (Dir : Scratch; Name, Text : String) is
   begin
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "repo/" & Name), Text);
      Git (Repo (Dir), "add", "-A");
      Git (Repo (Dir), "commit", "-q", "-m", "change");
   end Commit_Change;

   procedure Body_Gives_The_Brief_By_Default (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("body", "Engine core")) = 0, "success");
      Assert
        (F.Console.Out_Text =
         "summary: The engine." & LF & "crux: src/engine.ext:1-2" & LF &
         "## Links" & LF & "- uses [[Render]]" & LF & "- part_of [[Missing]]" &
         LF,
         "the brief: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Body_Gives_The_Brief_By_Default;

   procedure Body_Full_Is_The_Prose_Without_Frontmatter
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("body", "Engine core.md", "--full")) = 0,
         "success");
      Assert
        (Has (F.Console.Out_Text, "## Summary" & LF & "It does  things." & LF)
         or else Has (F.Console.Out_Text, "## Summary"),
         "the prose: " & F.Console.Out_Text);
      Assert (not Has (F.Console.Out_Text, "schema:"), "no frontmatter");
      Assert
        (not Has (F.Console.Out_Text, "## Notes"), "nothing after the fence");
      Assert
        (F.Console.Out_Text (F.Console.Out_Text'Last) = LF,
         "ends with a line feed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Body_Full_Is_The_Prose_Without_Frontmatter;

   procedure Body_Lines_Slices_The_Node_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("body", "Engine core", "--lines", "1-2,4")) = 0,
         "success");
      Assert
        (Has (F.Console.Out_Text, "---" & LF & "schema: graph-node/v1" & LF),
         "frontmatter included: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("body", "Engine core", "--lines", "900-901")) = 1,
         "past the end");
      Assert
        (F.Console.Err_Text =
         "synapse-query: --lines 900-901 starts past the last line of 'Engine core'" &
         LF,
         "says so: " & F.Console.Err_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("body", "Engine core", "--lines", "x")) = 2,
         "not ranges");
      Assert
        (F.Console.Err_Text =
         "synapse-query: --lines expects ranges like 12-14,40-41,88, got 'x'" &
         LF,
         "says so: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Body_Lines_Slices_The_Node_File;

   procedure Body_Of_A_Node_From_Before_The_Fence_Says_So
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Node_Path (Dir, "Old.md"),
         "---" & LF & "title: Old" & LF & "---" & LF & LF & "old body" & LF);
      Assert (Run (Env (F), Args ("body", "Old")) = 0, "brief");
      Assert
        (F.Console.Out_Text = LF & "old body" & LF
         or else Has (F.Console.Out_Text, "old body"),
         "everything after the frontmatter: " & F.Console.Out_Text);
      Assert
        (F.Console.Err_Text =
         "synapse-query: no generated fence in 'Old'; printing everything after the frontmatter" &
         LF,
         "announced: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Body_Of_A_Node_From_Before_The_Fence_Says_So;

   procedure Body_Needs_A_Node_And_A_Known_Mode (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("body")) = 2, "no node");
      Assert
        (Run (Env (F), Args ("body", "Engine core", "--wat")) = 2,
         "unknown mode");
      Assert (Run (Env (F), Args ("body", "Nope")) = 1, "no such node");
      Assert (Has (F.Console.Err_Text, "usage: synapse query"), "usage");
      Assert
        (Has (F.Console.Err_Text, "Synapse commands by question:"),
         "and the map for it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Body_Needs_A_Node_And_A_Known_Mode;

   procedure Sources_Lists_Counts_Groups_And_Filters
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("sources", "Engine core")) = 0, "all");
      Assert
        (F.Console.Out_Text = "README.md" & LF & "src/engine.ext" & LF,
         "the paths: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("sources", "Engine core", "--count")) = 0,
         "count");
      Assert (F.Console.Out_Text = "2" & LF, "two");
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("sources", "Engine core", "--modules")) = 0,
         "modules");
      Assert
        (Has (F.Console.Out_Text, "src" & HT & "1" & LF),
         "modules: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("sources", "Engine core", "--filter", "src")) = 0,
         "filter");
      Assert
        (F.Console.Out_Text = "src/engine.ext" & LF,
         "a substring: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("sources", "Engine core", "--filter", "zzz")) = 0,
         "no match");
      Assert (F.Console.Out_Text = "", "nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Sources_Lists_Counts_Groups_And_Filters;

   procedure Sources_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("sources")) = 2, "no node");
      Assert
        (Run (Env (F), Args ("sources", "Engine core", "--count", "x")) = 2,
         "count takes nothing");
      Assert
        (Run (Env (F), Args ("sources", "Engine core", "--filter")) = 2,
         "filter needs a pattern");
      Assert
        (Run (Env (F), Args ("sources", "Engine core", "--filter", "")) = 2,
         "not an empty one");
      Assert
        (Run (Env (F), Args ("sources", "Engine core", "--wat")) = 2,
         "unknown");
      Assert (Run (Env (F), Args ("sources", "Nope")) = 1, "no such node");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Sources_Arguments;

   procedure Field_Prints_One_Scalar (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("field", "Engine core", "title")) = 0, "success");
      Assert (F.Console.Out_Text = "Engine core" & LF, "the title");
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("field", "Engine core", "nope")) = 0,
         "an absent key");
      Assert (F.Console.Out_Text = "", "prints nothing");
      Assert
        (Run (Env (F), Args ("field", "Engine core", "sources")) = 2,
         "a list is not a scalar");
      Assert
        (Has
           (F.Console.Err_Text,
            "'sources' is a list, not a scalar field -- use: synapse query sources <node>" &
            LF),
         "points to sources: " & F.Console.Err_Text);
      Assert
        (Run (Env (F), Args ("field", "Nope", "title")) = 1, "no such node");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-query: no such file: " & Node_Path (Dir, "Nope.md") & LF),
         "names the file");
      Assert (Run (Env (F), Args ("field", "Engine core")) = 2, "no key");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Field_Prints_One_Scalar;

   procedure Field_Reads_A_File_That_Is_Not_A_Node
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run
           (Env (F),
            Args ("field", "--file", Path (Dir, "work/b-001.md"), "summary")) =
         0,
         "success");
      Assert
        (F.Console.Out_Text = "The engine." & LF,
         "the summary: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert
        (Run
           (Env (F), Args ("field", "--file", Path (Dir, "none"), "summary")) =
         1,
         "no such file");
      Assert
        (Run (Env (F), Args ("field", "--file", Path (Dir, "work/b-001.md"))) =
         2,
         "no key");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Field_Reads_A_File_That_Is_Not_A_Node;

   procedure Stale_Is_Silent_When_Every_Source_Matches
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("stale")) = 0, "success");
      Assert
        (F.Console.Out_Text = "" and then F.Console.Err_Text = "",
         "silent: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Stale_Is_Silent_When_Every_Source_Matches;

   procedure Stale_Names_The_Nodes_Whose_Files_Changed_Or_Went
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "repo/src/render.ext"), "changed" & LF);
      Ada.Directories.Delete_File (Path (Dir, "repo/README.md"));
      Assert (Run (Env (F), Args ("stale")) = 0, "success");
      Assert
        (Has (F.Console.Out_Text, "Render" & HT & "content changed" & LF),
         "changed: " & F.Console.Out_Text);
      Assert
        (Has (F.Console.Out_Text, "Engine core" & HT),
         "gone: " & F.Console.Out_Text);
      Assert (Has (F.Console.Out_Text, "README.md"), "names the file");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Stale_Names_The_Nodes_Whose_Files_Changed_Or_Went;

   procedure Stale_Needs_A_Readable_Index (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Ada.Directories.Delete_File (Path (Dir, "work/_index.bin"));
      Assert
        (Run (Env (F), Args ("stale")) = 0, "no index file lists no nodes");
      Assert (F.Console.Out_Text = "", "and says nothing");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/_index.bin"), "junk");
      Assert (Run (Env (F), Args ("stale")) = 1, "a damaged index");
      Assert (Run (Env (F), Args ("stale", "x")) = 2, "takes nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Stale_Needs_A_Readable_Index;

   procedure Stale_Says_A_Node_File_Is_Missing_From_The_Vault
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Ada.Directories.Delete_File (Node_Path (Dir, "Render.md"));
      Assert (Run (Env (F), Args ("stale")) = 0, "success");
      Assert
        (Has (F.Console.Out_Text, "Render" & HT),
         "named: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Stale_Says_A_Node_File_Is_Missing_From_The_Vault;

   procedure Drift_Is_Silent_While_The_Checkout_Is_At_The_Baseline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("drift")) = 0, "success");
      Assert (F.Console.Out_Text = "", "silent: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Drift_Is_Silent_While_The_Checkout_Is_At_The_Baseline;

   procedure Drift_Counts_The_Files_Changed_Since_The_Baseline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Commit_Change (Dir, "src/engine.ext", Engine_Source & "more" & LF);
      Assert (Run (Env (F), Args ("drift")) = 0, "success");
      Assert
        (Has (F.Console.Out_Text, "(repo)" & HT & "1 commits since baseline "),
         "commits: " & F.Console.Out_Text);
      Assert
        (Has
           (F.Console.Out_Text,
            "Engine core" & HT & "content changed in 1 of its files" & LF),
         "node: " & F.Console.Out_Text);
      Assert
        (not Has (F.Console.Out_Text, "Render" & HT), "the other is clean");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Drift_Counts_The_Files_Changed_Since_The_Baseline;

   procedure Drift_Names_Deleted_And_Renamed_Files
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Git (Repo (Dir), "rm", "-q", "README.md");
      Git (Repo (Dir), "mv", "src/render.ext", "src/draw.ext");
      Git (Repo (Dir), "commit", "-q", "-m", "moves");
      Assert (Run (Env (F), Args ("drift")) = 0, "success");
      Assert
        (Has
           (F.Console.Out_Text,
            "Engine core" & HT & "1 of its files are gone" & LF),
         "deleted: " & F.Console.Out_Text);
      Assert
        (Has
           (F.Console.Out_Text,
            "Render" & HT &
            "1 of its files were renamed -- reseat sources, prose may still hold" &
            LF),
         "renamed: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Drift_Names_Deleted_And_Renamed_Files;

   procedure Drift_Sorts_New_Paths_By_Whether_A_Manifest_Covers_Them
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Work (Dir, "manifest.tsv", "Engine core" & HT & "^src/" & HT & LF);
      Commit_Change (Dir, "src/extra.ext", "n" & LF);
      for C in Character range '1' .. '7' loop
         Put_File (Dir, "other/g" & C & ".txt", "n" & LF);
      end loop;
      Git (Repo (Dir), "add", "-A");
      Git (Repo (Dir), "commit", "-q", "-m", "more");
      Assert (Run (Env (F), Args ("drift")) = 0, "success");
      Assert
        (Has
           (F.Console.Out_Text,
            "(repo)" & HT &
            "1 new paths already match a manifest pattern -- re-run `synapse build-lists` to claim them" &
            LF),
         "covered: " & F.Console.Out_Text);
      Assert
        (Has
           (F.Console.Out_Text,
            "(repo)" & HT &
            "7 new paths match no manifest pattern: other/g1.txt other/g2.txt other/g3.txt other/g4.txt other/g5.txt " &
            LF),
         "uncovered: " & F.Console.Out_Text);
      F.Console.Clear;
      Ada.Directories.Delete_File (Path (Dir, "work/manifest.tsv"));
      Assert (Run (Env (F), Args ("drift")) = 0, "no manifest");
      Assert
        (Has
           (F.Console.Out_Text,
            "(repo)" & HT &
            "8 new paths claimed by no node, and no manifest to classify them against" &
            LF),
         "no manifest: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Drift_Sorts_New_Paths_By_Whether_A_Manifest_Covers_Them;

   procedure Drift_Cannot_Diff_A_Node_With_No_Baseline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Node_Path (Dir, "Render.md"),
         Ada.Strings.Fixed.Replace_Slice
           (Synapse.Adapters.File_Bytes.Read
              (Node_Path (Dir, "Render.md"), 100_000),
            1, 0, ""));
      declare
         Text      : constant String  :=
           Synapse.Adapters.File_Bytes.Read
             (Node_Path (Dir, "Render.md"), 100_000);
         At_Commit : constant Natural :=
           Ada.Strings.Fixed.Index (Text, "commit: ");
      begin
         Synapse.Adapters.File_Bytes.Write
           (Node_Path (Dir, "Render.md"),
            Text (Text'First .. At_Commit - 1) &
            "commit: 0123456789abcdef0123456789abcdef01234567" & LF &
            Text
              (Ada.Strings.Fixed.Index (Text, "" & LF, At_Commit) + 1 ..
                   Text'Last));
      end;
      Assert (Run (Env (F), Args ("drift")) = 0, "success");
      Assert
        (Has
           (F.Console.Out_Text,
            "Render" & HT &
            "baseline 0123456789ab not in local history -- verify with `stale`" &
            LF),
         "absent: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Drift_Cannot_Diff_A_Node_With_No_Baseline;

   procedure Drift_Reports_A_Baseline_The_Checkout_Is_Not_On
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Git (Repo (Dir), "checkout", "-q", "--orphan", "fresh");
      Git (Repo (Dir), "rm", "-rfq", ".");
      Put_File (Dir, "z.txt", "z" & LF);
      Git (Repo (Dir), "add", "-A");
      Git (Repo (Dir), "commit", "-q", "-m", "other line");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      Assert (Run (Env (F), Args ("drift")) = 0, "success");
      Assert
        (Has
           (F.Console.Out_Text,
            " is not an ancestor of HEAD: 1 commits only on the baseline, 1 only here -- the graph describes a different line" &
            LF),
         "divergent: " & F.Console.Out_Text);
      Assert
        (not Has (F.Console.Out_Text, "commits since baseline"),
         "the divergence line says it already: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Drift_Reports_A_Baseline_The_Checkout_Is_Not_On;

   procedure Drift_Says_How_Far_Behind_The_Upstream_Is
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Git
        (Path (Dir), "init", "-q", "--bare", "-b", "main",
         Path (Dir, "remote.git"));
      Git (Repo (Dir), "remote", "add", "up", Path (Dir, "remote.git"));
      Git (Repo (Dir), "push", "-q", "-u", "up", "main");
      Git (Repo (Dir), "commit", "-q", "--allow-empty", "-m", "ahead");
      Git (Repo (Dir), "push", "-q", "up", "main");
      Git (Repo (Dir), "reset", "-q", "--hard", "HEAD~1");
      Commit_Change (Dir, "src/engine.ext", Engine_Source & "x" & LF);
      Assert (Run (Env (F), Args ("drift")) = 0, "success");
      Assert
        (Has
           (F.Console.Out_Text,
            "(repo)" & HT & "1 commits behind up/main, as of the last fetch" &
            LF),
         "behind: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Drift_Says_How_Far_Behind_The_Upstream_Is;

   procedure Drift_And_Stale_Need_Real_Files_Under_An_Explicit_Namespace
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "");
      Assert
        (Run (Env (F), Args ("--namespace", "widget@main", "stale")) = 1,
         "stale");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-query: 'stale' needs widget@main's real files on disk -- set SYNAPSE_REPO_ROOT to its working tree" &
            LF),
         "says so: " & F.Console.Err_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("--namespace", "widget@main", "body", "Render")) =
         0,
         "a read of the vault needs none");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", Repo (Dir));
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("--namespace", "widget@main", "stale")) = 0,
         "with a root");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Drift_And_Stale_Need_Real_Files_Under_An_Explicit_Namespace;

   procedure Grounding_Is_Silent_While_The_Evidence_Holds
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("grounding")) = 0, "success");
      Assert (F.Console.Out_Text = "", "silent: " & F.Console.Out_Text);
      Assert
        (Run (Env (F), Args ("grounding", "Engine core", "--list")) = 0,
         "list");
      Assert
        (F.Console.Out_Text = "src/engine.ext" & HT & "1-2" & LF,
         "the grounding: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Grounding_Is_Silent_While_The_Evidence_Holds;

   procedure Grounding_Says_What_Became_Of_The_Evidence
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "repo/src/engine.ext"),
         "pub fn launch() void {}" & LF & "pub fn stop() void {}" & LF);
      Assert (Run (Env (F), Args ("grounding")) = 0, "changed");
      Assert
        (F.Console.Out_Text =
         "Engine core" & HT &
         "grounding changed: src/engine.ext 1-2 (re-check the claim resting on it)" &
         LF,
         "changed: " & F.Console.Out_Text);
      F.Console.Clear;
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "repo/src/engine.ext"), "new line" & LF & Engine_Source);
      Assert (Run (Env (F), Args ("grounding")) = 0, "moved");
      Assert
        (F.Console.Out_Text =
         "Engine core" & HT &
         "grounding moved: src/engine.ext 1-2 -> 2-3 (re-point, no reading needed)" &
         LF,
         "moved: " & F.Console.Out_Text);
      F.Console.Clear;
      Ada.Directories.Delete_File (Path (Dir, "repo/src/engine.ext"));
      Assert (Run (Env (F), Args ("grounding")) = 0, "gone");
      Assert
        (F.Console.Out_Text =
         "Engine core" & HT & "grounding file gone: src/engine.ext" & LF,
         "gone: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Grounding_Says_What_Became_Of_The_Evidence;

   procedure Grounding_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("grounding", "Engine core")) = 2,
         "a node needs --list");
      Assert
        (Run (Env (F), Args ("grounding", "Nope", "--list")) = 1,
         "no such node");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Grounding_Arguments;

   procedure Links_Lists_What_A_Node_Points_To_And_What_Points_To_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("links", "Engine core")) = 0, "outbound");
      Assert
        (F.Console.Out_Text =
         "part_of" & HT & "Missing" & LF & "uses" & HT & "Render" & LF,
         "sorted by relation: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("links", "Render", "--inbound")) = 0, "inbound");
      Assert
        (F.Console.Out_Text = "uses" & HT & "Engine core" & LF,
         "who points here: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Links_Lists_What_A_Node_Points_To_And_What_Points_To_It;

   procedure Links_Closure_Gives_The_Shortest_Depth_And_Stops_At_Cycles
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("links", "Engine core", "--closure")) = 0,
         "success");
      Assert
        (F.Console.Out_Text =
         "1" & HT & "Missing" & LF & "1" & HT & "Render" & LF,
         "reachable: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Links_Closure_Gives_The_Shortest_Depth_And_Stops_At_Cycles;

   procedure Links_Check_Names_The_Targets_That_Resolve_To_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("links", "--check")) = 0, "success");
      Assert
        (F.Console.Out_Text =
         "Engine core" & HT & "part_of -> Missing (no such node)" & LF,
         "dangling: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Links_Check_Names_The_Targets_That_Resolve_To_Nothing;

   procedure Links_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("links")) = 2, "nothing");
      Assert
        (Run (Env (F), Args ("links", "--check", "x")) = 2,
         "check takes nothing");
      Assert (Run (Env (F), Args ("links", "-x")) = 2, "a flag is not a node");
      Assert
        (Run (Env (F), Args ("links", "Render", "--wat")) = 2, "unknown mode");
      Assert
        (Run (Env (F), Args ("links", "Render", "--inbound", "x")) = 2,
         "too many");
      Assert (Run (Env (F), Args ("links", "Nope")) = 1, "no such node");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Links_Arguments;

   procedure Symbol_Prints_The_Hits_Of_An_Exact_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("symbol", "start", "Render")) = 0,
         "success: " & F.Console.Err_Text);
      Assert
        (F.Console.Out_Text =
         "start" & HT & "ref" & HT & "call" & HT & "src/render.ext:1" & HT &
         "start ()" & LF,
         "the hit: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("symbol", "star", "Render")) = 0,
         "a prefix is not the name");
      Assert (F.Console.Out_Text = "", "no hit");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Symbol_Prints_The_Hits_Of_An_Exact_Name;

   procedure Symbol_Says_What_It_Could_Not_Check (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args ("symbol", "start")) = 2, "no node");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-query: symbol needs a node; without one, `synapse callers start --all` lists every definition and reference repo-wide" &
            LF),
         "points to callers: " & F.Console.Err_Text);
      Assert (Run (Env (F), Args ("symbol")) = 2, "nothing");
      Assert (Run (Env (F), Args ("symbol", "x", "Nope")) = 1, "no such node");
      F.Console.Clear;
      Ada.Directories.Delete_File (Path (Dir, "repo/src/render.ext"));
      Assert
        (Run (Env (F), Args ("symbol", "start", "Render")) = 1,
         "a source gone");
      Assert
        (F.Console.Err_Text =
         "synapse-query: could not hash 'Render' sources" & LF,
         "says so: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Symbol_Says_What_It_Could_Not_Check;

   procedure Symbol_Does_Nothing_When_The_Cache_Is_Switched_Off
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_DISABLE_SYMBOL_CACHE", "1");
      Assert
        (Run (Env (F), Args ("symbol", "start", "Render")) = 0, "success");
      Assert
        (F.Console.Out_Text = "" and then F.Console.Err_Text = "", "nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Symbol_Does_Nothing_When_The_Cache_Is_Switched_Off;

   procedure Query_Needs_A_Known_Subcommand_And_A_Graph
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args) = 2, "nothing");
      Assert (Run (Env (F), Args ("wat")) = 2, "unknown");
      Assert (Run (Env (F), Args ("--namespace")) = 2, "dangling");
      Assert
        (Run (Env (F), Args ("--namespace", "widget@main")) = 2,
         "no subcommand");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Has
           (F.Console.Err_Text,
            "usage: synapse query [--namespace <repo>@<branch>] <subcommand> [args]"),
         "usage");
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("--namespace", "nope", "body", "Render")) = 1,
         "a bad namespace");
      Assert
        (Has
           (F.Console.Err_Text,
            "--namespace expects <repo>@<branch>, got 'nope'"),
         "says so: " & F.Console.Err_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("--namespace", "widget@zzz", "body", "Render")) =
         1,
         "no graph");
      Assert
        (Has
           (F.Console.Err_Text,
            "no namespace covers synapse/widget@zzz/ -- this branch has no graph"),
         "says so: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Query_Needs_A_Known_Subcommand_And_A_Graph;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Query");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Body_Gives_The_Brief_By_Default'Access,
         "Body gives the brief by default");
      Register_Routine
        (T, Body_Full_Is_The_Prose_Without_Frontmatter'Access,
         "Body full is the prose without frontmatter");
      Register_Routine
        (T, Body_Lines_Slices_The_Node_File'Access,
         "Body lines slices the node file");
      Register_Routine
        (T, Body_Of_A_Node_From_Before_The_Fence_Says_So'Access,
         "Body of a node from before the fence says so");
      Register_Routine
        (T, Body_Needs_A_Node_And_A_Known_Mode'Access,
         "Body needs a node and a known mode");
      Register_Routine
        (T, Sources_Lists_Counts_Groups_And_Filters'Access,
         "Sources lists counts groups and filters");
      Register_Routine (T, Sources_Arguments'Access, "Sources arguments");
      Register_Routine
        (T, Field_Prints_One_Scalar'Access, "Field prints one scalar");
      Register_Routine
        (T, Field_Reads_A_File_That_Is_Not_A_Node'Access,
         "Field reads a file that is not a node");
      Register_Routine
        (T, Stale_Is_Silent_When_Every_Source_Matches'Access,
         "Stale is silent when every source matches");
      Register_Routine
        (T, Stale_Names_The_Nodes_Whose_Files_Changed_Or_Went'Access,
         "Stale names the nodes whose files changed or went");
      Register_Routine
        (T, Stale_Needs_A_Readable_Index'Access,
         "Stale needs a readable index");
      Register_Routine
        (T, Stale_Says_A_Node_File_Is_Missing_From_The_Vault'Access,
         "Stale says a node file is missing from the vault");
      Register_Routine
        (T, Drift_Is_Silent_While_The_Checkout_Is_At_The_Baseline'Access,
         "Drift is silent while the checkout is at the baseline");
      Register_Routine
        (T, Drift_Counts_The_Files_Changed_Since_The_Baseline'Access,
         "Drift counts the files changed since the baseline");
      Register_Routine
        (T, Drift_Names_Deleted_And_Renamed_Files'Access,
         "Drift names deleted and renamed files");
      Register_Routine
        (T, Drift_Sorts_New_Paths_By_Whether_A_Manifest_Covers_Them'Access,
         "Drift sorts new paths by whether a manifest covers them");
      Register_Routine
        (T, Drift_Cannot_Diff_A_Node_With_No_Baseline'Access,
         "Drift cannot diff a node with no baseline");
      Register_Routine
        (T, Drift_Reports_A_Baseline_The_Checkout_Is_Not_On'Access,
         "Drift reports a baseline the checkout is not on");
      Register_Routine
        (T, Drift_Says_How_Far_Behind_The_Upstream_Is'Access,
         "Drift says how far behind the upstream is");
      Register_Routine
        (T, Drift_And_Stale_Need_Real_Files_Under_An_Explicit_Namespace'Access,
         "Drift and stale need real files under an explicit namespace");
      Register_Routine
        (T, Grounding_Is_Silent_While_The_Evidence_Holds'Access,
         "Grounding is silent while the evidence holds");
      Register_Routine
        (T, Grounding_Says_What_Became_Of_The_Evidence'Access,
         "Grounding says what became of the evidence");
      Register_Routine (T, Grounding_Arguments'Access, "Grounding arguments");
      Register_Routine
        (T, Links_Lists_What_A_Node_Points_To_And_What_Points_To_It'Access,
         "Links lists what a node points to and what points to it");
      Register_Routine
        (T, Links_Closure_Gives_The_Shortest_Depth_And_Stops_At_Cycles'Access,
         "Links closure gives the shortest depth and stops at cycles");
      Register_Routine
        (T, Links_Check_Names_The_Targets_That_Resolve_To_Nothing'Access,
         "Links check names the targets that resolve to nothing");
      Register_Routine (T, Links_Arguments'Access, "Links arguments");
      Register_Routine
        (T, Symbol_Prints_The_Hits_Of_An_Exact_Name'Access,
         "Symbol prints the hits of an exact name");
      Register_Routine
        (T, Symbol_Says_What_It_Could_Not_Check'Access,
         "Symbol says what it could not check");
      Register_Routine
        (T, Symbol_Does_Nothing_When_The_Cache_Is_Switched_Off'Access,
         "Symbol does nothing when the cache is switched off");
      Register_Routine
        (T, Query_Needs_A_Known_Subcommand_And_A_Graph'Access,
         "Query needs a known subcommand and a graph");
   end Register_Tests;

end Synapse.Commands.Query.Tests;
