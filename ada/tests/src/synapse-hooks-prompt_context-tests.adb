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
with AUnit.Assertions;

package body Synapse.Hooks.Prompt_Context.Tests is

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

   procedure The_Line_Names_The_Graph_Its_Nodes_And_The_Rules_For_Reading_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Feed
        (F,
         "{""prompt"": ""how does it work"", ""cwd"": " & Quote (Repo (Dir)) &
         "}");
      Run (Env (F));
      declare
         Out_Text : constant String := F.Console.Out_Text;
      begin
         Assert
           (Has (Out_Text, """hookEventName"":""UserPromptSubmit"""),
            "the event");
         Assert
           (Has
              (Out_Text,
               "this repo has a code graph at " &
               Path (Dir, "vault/synapse/widget@main") &
               "/ (2 nodes). Query it FIRST"),
            "the graph: " & Out_Text);
         Assert
           (Has
              (Out_Text,
               "Do not grep or open source files until Synapse has named the file to read."),
            "the order");
         Assert (not Has (Out_Text, "Code Cache"), "no code cache yet");
         Assert
           (Has
              (Out_Text,
               "trust the file over the graph. The synapse-query skill has the procedure."),
            "the scope");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Line_Names_The_Graph_Its_Nodes_And_The_Rules_For_Reading_It;

   procedure The_Line_Names_The_Code_Cache_Once_There_Is_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Work (Dir, "_refs.tsv", "");
      Feed (F, "{""prompt"": ""x"", ""cwd"": " & Quote (Repo (Dir)) & "}");
      Run (Env (F));
      Assert
        (Has
           (F.Console.Out_Text,
            "`synapse callers <name>` gives repo-wide call sites from the Code Cache -- use it, not grep."),
         "named: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Line_Names_The_Code_Cache_Once_There_Is_One;

   procedure Nothing_Is_Said_Without_A_Prompt_Or_When_It_Is_Switched_Off
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Feed (F, "{""prompt"": """", ""cwd"": " & Quote (Repo (Dir)) & "}");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "an empty prompt");
      Feed (F, "{""cwd"": " & Quote (Repo (Dir)) & "}");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "no prompt");
      Feed (F, "{""prompt"": ""x"", ""cwd"": " & Quote (Repo (Dir)) & "}");
      F.Vars.Set ("SYNAPSE_DISABLE_PROMPT_INJECTION", "");
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "switched off, whatever the value");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Nothing_Is_Said_Without_A_Prompt_Or_When_It_Is_Switched_Off;

   procedure Nothing_Is_Said_For_Another_Project_S_Graph_Or_No_Graph
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_REMOTE", "https://example.com/o/other.git");
      Assert (not Build (Env (F), Repo (Dir)).Found, "another remote");
      F.Vars.Set ("SYNAPSE_REMOTE", Remote);
      Assert (Build (Env (F), Repo (Dir)).Found, "this one");
      Ada.Directories.Delete_File
        (Path (Dir, "vault/synapse/widget@main/Render.md"));
      Ada.Directories.Delete_File
        (Path (Dir, "vault/synapse/widget@main/Engine core.md"));
      Assert (not Build (Env (F), Repo (Dir)).Found, "no nodes");
      Ada.Directories.Delete_File
        (Path (Dir, "vault/synapse/widget@main/Index.md"));
      Assert (not Build (Env (F), Repo (Dir)).Found, "no index");
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "nowhere"));
      Assert (not Build (Env (F), Repo (Dir)).Found, "no vault");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Nothing_Is_Said_For_Another_Project_S_Graph_Or_No_Graph;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Hooks.Prompt_Context");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T,
         The_Line_Names_The_Graph_Its_Nodes_And_The_Rules_For_Reading_It'
           Access,
         "The line names the graph, its nodes and the rules for reading it");
      Register_Routine
        (T, The_Line_Names_The_Code_Cache_Once_There_Is_One'Access,
         "The line names the code cache once there is one");
      Register_Routine
        (T, Nothing_Is_Said_Without_A_Prompt_Or_When_It_Is_Switched_Off'Access,
         "Nothing is said without a prompt or when it is switched off");
      Register_Routine
        (T, Nothing_Is_Said_For_Another_Project_S_Graph_Or_No_Graph'Access,
         "Nothing is said for another project's graph or no graph");
   end Register_Tests;

end Synapse.Hooks.Prompt_Context.Tests;
