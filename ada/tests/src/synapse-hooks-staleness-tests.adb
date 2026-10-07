with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with Synapse.Commands.Index;
with Synapse.Commands.Project_Index;
with Synapse.Commands.Push_Nodes;
with Synapse.Hooks.Common;
with Synapse.Adapters.Docstring_Cache;
with Synapse.Adapters.Index_Map;
with Synapse.Core.Hashing;
with GNAT.OS_Lib;
with Ada.Calendar;
with AUnit.Assertions;

package body Synapse.Hooks.Staleness.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
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

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure Work (Dir : Scratch; Name, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path (Dir, "work/" & Name)));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work/" & Name), Text);
   end Work;

   function Node (Dir : Scratch; File : String) return String is
     (Synapse.Adapters.File_Bytes.Read
        (Path (Dir, "vault/synapse/widget@main/" & File), 1_000_000));

   --  The context pinned to a checkout on `main`; no graph yet.
   procedure Pin (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      F.Clock.Now := To_Unbounded_String ("2026-09-07T14:32:05+02:00");
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      Put_File (Dir, "src/engine.ext", Engine_Source);
      Put_File (Dir, "src/render.ext", "paint" & LF);
      Put_File (Dir, "README.md", "hello" & LF);
      Commit_All (Dir);
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", Repo (Dir));
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", Remote);
   end Pin;

   procedure Feed (F : aliased in out Fixture; Text : String) is
   begin
      F.Console.Set_Stdin (Text);
   end Feed;

   function Quote (Text : String) return String is ("""" & Text & """");

   --  Two nodes written by `push-nodes`, an index and a vault that agrees.
   procedure Setup (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Pin (F, Dir);
      Put_Schema
        (Dir, "graph-node/v1",
         Synapse.Adapters.File_Bytes.Read
           ("../../packages/synapse/schema/graph-node/v1.yaml", 100_000));
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
         "## Links" & LF & "- uses [[Render]]" & LF);
      Work
        (Dir, "b-002.md",
         "---" & LF & "summary: Render." & LF & "---" & LF & LF &
         "## Summary" & LF & "Paints." & LF & LF & "## Crux" & LF &
         "<!-- crux: none -->" & LF & LF & "## Links" & LF &
         "- needs [[Engine core]]" & LF);
      F.Vars.Set ("SYNAPSE_DISABLE_SYMBOL_CACHE", "1");
      Assert
        (Synapse.Commands.Push_Nodes.Run (Env (F), Args) = 0,
         "pushed: " & F.Console.Err_Text);
      Assert
        (Synapse.Commands.Project_Index.Run (Env (F), Args) = 0,
         "indexed nodes");
      Assert
        (Synapse.Commands.Index.Run_Build_Index (Env (F), Args) = 0,
         "indexed paths");
      F.Console.Clear;
   end Setup;

   procedure Edit (Dir : Scratch; Name, Text : String) is
   begin
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "repo/" & Name), Text);
   end Edit;

   function Node_Path_For (Dir : Scratch; File : String) return String is
     (Path (Dir, "vault/synapse/widget@main/" & File));

   use type Ada.Calendar.Time;

   procedure An_Edit_Flags_The_Owning_Node_As_Stale
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Edit (Dir, "src/engine.ext", Engine_Source & "more" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/engine.ext")) & "}}");
      Run (Env (F));
      Assert
        (Has (Node (Dir, "Engine core.md"), "stale: true" & LF),
         "flagged: " & Node (Dir, "Engine core.md"));
      Assert
        (Has (Node (Dir, "Render.md"), "stale: false" & LF),
         "the other is not");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Edit_Flags_The_Owning_Node_As_Stale;

   procedure An_Edit_That_Breaks_Cited_Evidence_Says_Which
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Edit
        (Dir, "src/engine.ext",
         "pub fn go() void {}" & LF & "pub fn stop() void {}" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/engine.ext")) & "}}");
      Run (Env (F));
      declare
         Text : constant String := F.Console.Out_Text;
      begin
         Assert (Has (Text, """hookEventName"":""PostToolUse"""), "the event");
         Assert
           (Has
              (Text,
               "You just edited a file that these Synapse nodes cite as evidence"),
            "the opening: " & Text);
         Assert (Has (Text, "  - Engine core"), "the node");
         Assert (Has (Text, "crux (src/engine.ext:1-2)"), "the crux");
         Assert
           (Has (Text, "grounding (src/engine.ext:1-2)"), "the grounding");
         Assert
           (Has (Text, "Do NOT re-read the node's other sources"),
            "and the restraint");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Edit_That_Breaks_Cited_Evidence_Says_Which;

   procedure An_Edit_That_Leaves_The_Evidence_Alone_Says_Nothing_Of_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Edit (Dir, "README.md", "changed" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/README.md")) & "}}");
      Run (Env (F));
      Assert
        (not Has (F.Console.Out_Text, "cite as evidence"),
         "no citation said: " & F.Console.Out_Text);
      Assert
        (Has (F.Console.Out_Text, "other nodes depend on"),
         "only the dependents");
      Assert
        (Has (Node (Dir, "Engine core.md"), "stale: true" & LF),
         "and the node is flagged");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Edit_That_Leaves_The_Evidence_Alone_Says_Nothing_Of_It;

   procedure An_Edit_Says_Which_Nodes_Depend_On_The_Owners_Once
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Edit (Dir, "src/render.ext", "paint again" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/render.ext")) & "}}");
      Run (Env (F));
      Assert
        (Has
           (F.Console.Out_Text,
            "This file is covered by a Synapse node that other nodes depend on:\n  - Engine core\n"),
         "named: " & F.Console.Out_Text);
      F.Console.Clear;
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/render.ext")) & "}}");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "not again in the same session");
      Feed
        (F,
         "{""session_id"": ""s2"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/render.ext")) & "}}");
      Run (Env (F));
      Assert (Has (F.Console.Out_Text, "Engine core"), "but in another");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Edit_Says_Which_Nodes_Depend_On_The_Owners_Once;

   procedure A_File_No_Node_Owns_Is_Queued_As_Unassigned
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_File (Dir, "extra.txt", "new" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/extra.txt")) & "}}");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "quiet");
      declare
         Map : Synapse.Adapters.Index_Map.Map;
      begin
         Synapse.Adapters.Index_Map.Open (Map, Path (Dir, "work/_index.bin"));
         Assert
           (Synapse.Adapters.Index_Map.Unassigned (Map).Contains
              (To_Unbounded_String ("extra.txt")),
            "queued");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_File_No_Node_Owns_Is_Queued_As_Unassigned;

   procedure An_Edit_Of_A_File_The_Hook_Cannot_Place_Says_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/gone.txt")) & "}}");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "a file that is not there");
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "outside.txt")) & "}}");
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "outside.txt"), "x");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "a file outside the repository");
      Feed (F, "{""session_id"": ""s1""}");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "no file at all");
      Feed (F, "");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "no payload");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Edit_Of_A_File_The_Hook_Cannot_Place_Says_Nothing;

   procedure A_Namespace_Of_Another_Remote_Is_Left_Alone
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Edit (Dir, "src/engine.ext", Engine_Source & "more" & LF);
      F.Vars.Set ("SYNAPSE_REMOTE", "https://example.com/o/other.git");
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/engine.ext")) & "}}");
      Run (Env (F));
      Assert
        (Has (Node (Dir, "Engine core.md"), "stale: false" & LF),
         "not flagged");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Namespace_Of_Another_Remote_Is_Left_Alone;

   procedure Without_An_Index_Only_The_Docstrings_Are_Looked_At
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Ada.Directories.Delete_File (Path (Dir, "work/_index.bin"));
      Edit (Dir, "src/engine.ext", Engine_Source & "more" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/engine.ext")) & "}}");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "quiet");
      Assert
        (Has (Node (Dir, "Engine core.md"), "stale: false" & LF),
         "nothing flagged");
      Assert
        (not Ada.Directories.Exists (Path (Dir, "work/_index.bin")),
         "and no index written out of nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Without_An_Index_Only_The_Docstrings_Are_Looked_At;

   procedure The_Tool_S_Other_Payload_Shapes_Name_The_File_Too
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Edit (Dir, "README.md", "changed" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_response"": {""filePath"": " &
         Quote (Path (Dir, "repo/README.md")) & "}}");
      Run (Env (F));
      Assert
        (Has (Node (Dir, "Engine core.md"), "stale: true" & LF),
         "by filePath");
      Synapse.Adapters.File_Bytes.Write
        (Node_Path_For (Dir, "Engine core.md"),
         Ada.Strings.Fixed.Replace_Slice
           (Node (Dir, "Engine core.md"),
            Ada.Strings.Fixed.Index
              (Node (Dir, "Engine core.md"), "stale: true"),
            Ada.Strings.Fixed.Index
              (Node (Dir, "Engine core.md"), "stale: true") +
            10,
            "stale: false"));
      Feed
        (F,
         "{""session_id"": ""s1"", ""cwd"": " & Quote (Path (Dir, "repo")) &
         ", ""tool_input"": {""command"": ""*** Begin Patch\n*** Update File: README.md\n@@\n*** End Patch""}}");
      Run (Env (F));
      Assert
        (Has (Node (Dir, "Engine core.md"), "stale: true" & LF),
         "by apply_patch");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Tool_S_Other_Payload_Shapes_Name_The_File_Too;

   procedure A_Docstring_Edited_Since_It_Was_Checked_Is_Reported
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "1");
      Edit (Dir, "src/doc.ext", "// Starts it." & LF & "fn start()" & LF);
      declare
         Cache  : Synapse.Adapters.Docstring_Cache.Cache;
         Update : Synapse.Adapters.Docstring_Cache.Update_Vectors.Vector;
         Doc    : constant String := "// Starts it.";
      begin
         Synapse.Adapters.Docstring_Cache.Open
           (Cache, Path (Dir, "work/_docstring_index.bin"));
         Update.Append
           (Synapse.Adapters.Docstring_Cache.Update'
              (Where =>
                 (Path => To_Unbounded_String ("src/doc.ext"),
                  Name => To_Unbounded_String ("fn start()"),
                  Kind => To_Unbounded_String ("function")),
               Which =>
                 (Docstring_Hash  =>
                    Synapse.Core.Hashing.Sha256_Raw ("// Starts it." & LF),
                  Decl_Hash       =>
                    Synapse.Core.Hashing.Sha256_Raw ("fn start()" & LF),
                  Docstring_Start => 1, Docstring_End => 1, Decl_Start => 2,
                  Decl_End        => 2)));
         Assert
           (Synapse.Adapters.Docstring_Cache.Commit
              (Cache, Update,
               Synapse.Adapters.Docstring_Cache.Key_Vectors.Empty_Vector) =
            0,
            "committed" & Doc);
      end;
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/doc.ext")) & "}}");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "unchanged is quiet");
      Edit
        (Dir, "src/doc.ext",
         "// Starts it, which used to be slow." & LF & "fn start()" & LF);
      F.Console.Clear;
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/doc.ext")) & "}}");
      Run (Env (F));
      Assert
        (Has
           (F.Console.Out_Text,
            "Docstring staleness: these declarations' docstrings or bodies changed since they were last checked:"),
         "reported: " & F.Console.Out_Text);
      Assert
        (Has
           (F.Console.Out_Text,
            "- `fn start()` (function): the docstring changed since last checked"),
         "which");
      Assert
        (Has (F.Console.Out_Text, "historian-plague tell: \""used to"),
         "and its tell: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Docstring_Edited_Since_It_Was_Checked_Is_Reported;

   procedure A_Node_That_Links_To_Itself_Does_Not_Depend_On_Itself
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Node_Path_For (Dir, "Engine core.md"),
         Ada.Strings.Fixed.Replace_Slice
           (Node (Dir, "Engine core.md"),
            Ada.Strings.Fixed.Index
              (Node (Dir, "Engine core.md"), "- uses [[Render]]"),
            Ada.Strings.Fixed.Index
              (Node (Dir, "Engine core.md"), "- uses [[Render]]") +
            16,
            "- uses [[Render]]" & LF & "- self [[Engine core]]"));
      Edit (Dir, "README.md", "changed" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/README.md")) & "}}");
      Run (Env (F));
      Assert
        (Has (F.Console.Out_Text, "  - Render\n"),
         "the other node: " & F.Console.Out_Text);
      Assert
        (not Has (F.Console.Out_Text, "  - Engine core"),
         "not itself: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Node_That_Links_To_Itself_Does_Not_Depend_On_Itself;

   procedure At_Most_Five_Dependents_Are_Named (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      for C in Character range '1' .. '7' loop
         Put
           (Dir, "synapse/widget@main/D" & C & ".md",
            "---" & LF & "title: D" & C & LF & "---" & LF & LF & "## Links" &
            LF & "- uses [[Engine core]]" & LF);
      end loop;
      Edit (Dir, "README.md", "changed" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/README.md")) & "}}");
      Run (Env (F));
      Assert
        (Has
           (F.Console.Out_Text,
            "  - D1\n  - D2\n  - D3\n  - D4\n  - D5\n  (+3 more)\n"),
         "five and the rest counted: " & F.Console.Out_Text);
      Assert (not Has (F.Console.Out_Text, "  - D6"), "not the sixth");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end At_Most_Five_Dependents_Are_Named;

   procedure A_Node_Already_Flagged_Stale_Is_Not_Rewritten
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Edit (Dir, "README.md", "changed" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/README.md")) & "}}");
      Run (Env (F));
      Assert
        (Has (Node (Dir, "Engine core.md"), "stale: true" & LF), "flagged");
      GNAT.OS_Lib.Set_File_Last_Modify_Time_Stamp
        (Node_Path_For (Dir, "Engine core.md"),
         GNAT.OS_Lib.GM_Time_Of (2_020, 1, 1, 0, 0, 0));
      Feed
        (F,
         "{""session_id"": ""s3"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/README.md")) & "}}");
      Run (Env (F));
      Assert
        (Ada.Directories.Modification_Time
           (Node_Path_For (Dir, "Engine core.md")) <
         Ada.Calendar.Time_Of (2_021, 1, 1),
         "left as it was");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Node_Already_Flagged_Stale_Is_Not_Rewritten;

   procedure A_Docstring_And_Its_Declaration_Are_Reported_Apart_Or_Together
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "1");
      declare
         Cache  : Synapse.Adapters.Docstring_Cache.Cache;
         Update : Synapse.Adapters.Docstring_Cache.Update_Vectors.Vector;
      begin
         Synapse.Adapters.Docstring_Cache.Open
           (Cache, Path (Dir, "work/_docstring_index.bin"));
         Update.Append
           (Synapse.Adapters.Docstring_Cache.Update'
              (Where =>
                 (Path => To_Unbounded_String ("src/doc.ext"),
                  Name => To_Unbounded_String ("fn start()"),
                  Kind => To_Unbounded_String ("function")),
               Which =>
                 (Docstring_Hash  =>
                    Synapse.Core.Hashing.Sha256_Raw ("// Starts it." & LF),
                  Decl_Hash       =>
                    Synapse.Core.Hashing.Sha256_Raw ("fn start()" & LF),
                  Docstring_Start => 1, Docstring_End => 1, Decl_Start => 2,
                  Decl_End        => 2)));
         Assert
           (Synapse.Adapters.Docstring_Cache.Commit
              (Cache, Update,
               Synapse.Adapters.Docstring_Cache.Key_Vectors.Empty_Vector) =
            0,
            "committed");
      end;
      Edit (Dir, "src/doc.ext", "// Starts it." & LF & "fn start(x)" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/doc.ext")) & "}}");
      Run (Env (F));
      Assert
        (Has
           (F.Console.Out_Text,
            "): the declaration changed since last checked"),
         "declaration: " & F.Console.Out_Text);
      F.Console.Clear;
      Edit
        (Dir, "src/doc.ext",
         "// Starts it differently." & LF & "fn start(x)" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/doc.ext")) & "}}");
      Run (Env (F));
      Assert
        (Has
           (F.Console.Out_Text,
            "): the docstring and the declaration both changed since last checked"),
         "both: " & F.Console.Out_Text);
      F.Console.Clear;
      Edit (Dir, "src/doc.ext", "// Starts it." & LF & "fn start()" & LF);
      Feed
        (F,
         "{""session_id"": ""s1"", ""tool_input"": {""file_path"": " &
         Quote (Path (Dir, "repo/src/doc.ext")) & "}}");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "and neither when nothing changed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Docstring_And_Its_Declaration_Are_Reported_Apart_Or_Together;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Hooks.Staleness");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Edit_Flags_The_Owning_Node_As_Stale'Access,
         "An edit flags the owning node as stale");
      Register_Routine
        (T, An_Edit_That_Breaks_Cited_Evidence_Says_Which'Access,
         "An edit that breaks cited evidence says which");
      Register_Routine
        (T, An_Edit_That_Leaves_The_Evidence_Alone_Says_Nothing_Of_It'Access,
         "An edit that leaves the evidence alone says nothing of it");
      Register_Routine
        (T, An_Edit_Says_Which_Nodes_Depend_On_The_Owners_Once'Access,
         "An edit says which nodes depend on the owners, once");
      Register_Routine
        (T, A_File_No_Node_Owns_Is_Queued_As_Unassigned'Access,
         "A file no node owns is queued as unassigned");
      Register_Routine
        (T, An_Edit_Of_A_File_The_Hook_Cannot_Place_Says_Nothing'Access,
         "An edit of a file the hook cannot place says nothing");
      Register_Routine
        (T, A_Namespace_Of_Another_Remote_Is_Left_Alone'Access,
         "A namespace of another remote is left alone");
      Register_Routine
        (T, Without_An_Index_Only_The_Docstrings_Are_Looked_At'Access,
         "Without an index only the docstrings are looked at");
      Register_Routine
        (T, The_Tool_S_Other_Payload_Shapes_Name_The_File_Too'Access,
         "The tool's other payload shapes name the file too");
      Register_Routine
        (T, A_Docstring_Edited_Since_It_Was_Checked_Is_Reported'Access,
         "A docstring edited since it was checked is reported");
      Register_Routine
        (T, A_Node_That_Links_To_Itself_Does_Not_Depend_On_Itself'Access,
         "A node that links to itself does not depend on itself");
      Register_Routine
        (T, At_Most_Five_Dependents_Are_Named'Access,
         "At most five dependents are named");
      Register_Routine
        (T, A_Node_Already_Flagged_Stale_Is_Not_Rewritten'Access,
         "A node already flagged stale is not rewritten");
      Register_Routine
        (T,
         A_Docstring_And_Its_Declaration_Are_Reported_Apart_Or_Together'Access,
         "A docstring and its declaration are reported apart or together");
   end Register_Tests;

end Synapse.Hooks.Staleness.Tests;
