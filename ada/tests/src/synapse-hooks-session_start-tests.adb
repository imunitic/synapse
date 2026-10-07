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

package body Synapse.Hooks.Session_Start.Tests is

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

   procedure A_Session_Starts_With_The_Vault_Index_And_The_Pointer_To_Its_Graph
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "vault/Index.md"), "# vault index" & LF);
      Feed (F, "{""cwd"": " & Quote (Repo (Dir)) & "}");
      Run (Env (F));
      declare
         Text : constant String := F.Console.Out_Text;
      begin
         Assert
           (Has (Text, """hookEventName"":""SessionStart"""), "the event");
         Assert
           (Has
              (Text,
               "Synapse Vault index (" & Path (Dir, "vault/Index.md") & ")"),
            "the index: " & Text);
         Assert (Has (Text, "# vault index"), "its text");
         Assert
           (Has
              (Text,
               "Synapse namespace for this repo and branch: " &
               Path (Dir, "vault/synapse/widget@main/Index.md") &
               " -- consult it for existing code-graph nodes before re-exploring from scratch."),
            "the pointer");
         Assert
           (Has (Text, "Synapse commands by question:"),
            "and the map of commands");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Session_Starts_With_The_Vault_Index_And_The_Pointer_To_Its_Graph;

   procedure The_Pointer_Says_How_Many_Nodes_Cover_Files_That_Changed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Edit (Dir, "src/engine.ext", Engine_Source & "more" & LF);
      Git (Repo (Dir), "commit", "-q", "-am", "change");
      Assert
        (Has
           (To_String (Build (Env (F), Repo (Dir)).Value),
            "1 graph node covers files changed since it was built -- /synapse-rebuild-diff brings the graph up to date."),
         "one");
      Edit (Dir, "src/render.ext", "other" & LF);
      Git (Repo (Dir), "commit", "-q", "-am", "change");
      Assert
        (Has
           (To_String (Build (Env (F), Repo (Dir)).Value),
            "2 graph nodes cover files changed since they were built"),
         "two");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Pointer_Says_How_Many_Nodes_Cover_Files_That_Changed;

   procedure Without_A_Vault_It_Says_How_To_Configure_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "nowhere"));
      declare
         Text : constant Common.Maybe_Text := Build (Env (F), Repo (Dir));
      begin
         Assert (Text.Found, "says it");
         Assert
           (Has
              (To_String (Text.Value),
               "Synapse Vault isn't configured, or its directory isn't reachable"),
            "named: " & To_String (Text.Value));
         Assert
           (not Has (To_String (Text.Value), "Synapse namespace"),
            "and nothing of the graph");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Without_A_Vault_It_Says_How_To_Configure_One;

   procedure A_Vault_With_No_Index_Offers_To_Seed_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      declare
         Where : constant Common.Maybe_Text := Build (Env (F), Repo (Dir));
      begin
         Assert
           (Has
              (To_String (Where.Value),
               "No Index.md found at " & Path (Dir, "vault/Index.md") &
               " -- the configured Synapse Vault has no index yet. Offer to seed it from the shipped default ("),
            "offered: " & To_String (Where.Value));
      end;
      F.Vars.Set ("CLAUDE_PLUGIN_ROOT", Path (Dir, "plugin"));
      Assert
        (Has
           (To_String (Build (Env (F), Repo (Dir)).Value),
            "(" & Path (Dir, "plugin") & "/Index.md.template)"),
         "from the plugin root");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Vault_With_No_Index_Offers_To_Seed_One;

   procedure A_Graph_Whose_Remote_Differs_Is_Not_Pointed_At
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_REMOTE", "https://example.com/o/other.git");
      declare
         Text : constant String :=
           To_String (Build (Env (F), Repo (Dir)).Value);
      begin
         Assert
           (Has
              (Text,
               "Synapse namespace synapse/widget@main/ exists but its remote (""" &
               Remote &
               """) doesn't match this repo's (""https://example.com/o/other.git"")"),
            "named: " & Text);
         Assert
           (Has (Text, "rebuild the namespace with /synapse-rebuild-full."),
            "and the remedy");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Graph_Whose_Remote_Differs_Is_Not_Pointed_At;

   procedure A_Branch_With_No_Graph_Is_Told_So_And_Where_Its_Siblings_Are
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@feature");
      declare
         Text : constant String :=
           To_String (Build (Env (F), Repo (Dir)).Value);
      begin
         Assert
           (Has
              (Text,
               "No Synapse namespace covers synapse/widget@feature/ -- this branch has no code graph of its own, and a short-lived branch does not need one. This repo does have a graph on another branch: " &
               Path (Dir, "vault/synapse/widget@main/") & "."),
            "sibling: " & Text);
         Assert
           (Has
              (Text,
               "`synapse query --namespace widget@main body ""<Node>""`"),
            "how to read it");
      end;
      F.Vars.Set ("SYNAPSE_REMOTE", "https://example.com/o/lonely.git");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "vault/Index.md"), "# i" & LF);
      declare
         Text : constant String :=
           To_String (Build (Env (F), Repo (Dir)).Value);
      begin
         Assert
           (Has
              (Text,
               "No Synapse namespace covers synapse/widget@feature/ -- this branch has no code graph. That is normal; /synapse-init builds one if it is worth it."),
            "no sibling: " & Text);
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Branch_With_No_Graph_Is_Told_So_And_Where_Its_Siblings_Are;

   procedure The_Other_Namespaces_Are_Listed_By_Name_And_Remote
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put
        (Dir, "synapse/other@main/Index.md",
         "---" & LF & "remote: ""https://x/other.git""" & LF & "branch: main" &
         LF & "---" & LF);
      Put
        (Dir, "synapse/noremote@main/Index.md",
         "---" & LF & "branch: main" & LF & "---" & LF);
      declare
         Text : constant String :=
           To_String (Build (Env (F), Repo (Dir)).Value);
      begin
         Assert
           (Has
              (Text,
               "Other Synapse namespaces in this vault (name | remote)."),
            "heading: " & Text);
         Assert
           (Has (Text, "built from:" & LF & "other@main|https://x/other.git"),
            "listed");
         Assert (not Has (Text, "widget@main|"), "not this repo's own");
         Assert (not Has (Text, "noremote@main|"), "nor one with no remote");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Other_Namespaces_Are_Listed_By_Name_And_Remote;

   procedure The_Standing_Instructions_Come_From_The_First_Root_That_Has_Them
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "content/synapse-claude.md"), "FROM CONTENT" & LF);
      Assert
        (Has (To_String (Build (Env (F), Repo (Dir)).Value), "FROM CONTENT"),
         "the content root");
      Ada.Directories.Create_Path (Path (Dir, "plugin"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "plugin/synapse-claude.md"), "FROM PLUGIN" & LF);
      F.Vars.Set ("CLAUDE_PLUGIN_ROOT", Path (Dir, "plugin"));
      Assert
        (Has (To_String (Build (Env (F), Repo (Dir)).Value), "FROM PLUGIN"),
         "the plugin root first");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Standing_Instructions_Come_From_The_First_Root_That_Has_Them;

   procedure Nothing_Is_Said_Outside_A_Repository_With_Nothing_Configured
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      F.Vars.Set ("SYNAPSE_VAULT_DIR", "");
      F.Vars.Set ("HOME", Path (Dir, "empty-home"));
      declare
         Text : constant Common.Maybe_Text := Build (Env (F), Path (Dir));
      begin
         Assert
           (Text.Found
            and then Has (To_String (Text.Value), "isn't configured"),
            "only the warning");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Nothing_Is_Said_Outside_A_Repository_With_Nothing_Configured;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Hooks.Session_Start");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T,
         A_Session_Starts_With_The_Vault_Index_And_The_Pointer_To_Its_Graph'
           Access,
         "A session starts with the vault index and the pointer to its graph");
      Register_Routine
        (T, The_Pointer_Says_How_Many_Nodes_Cover_Files_That_Changed'Access,
         "The pointer says how many nodes cover files that changed");
      Register_Routine
        (T, Without_A_Vault_It_Says_How_To_Configure_One'Access,
         "Without a vault it says how to configure one");
      Register_Routine
        (T, A_Vault_With_No_Index_Offers_To_Seed_One'Access,
         "A vault with no index offers to seed one");
      Register_Routine
        (T, A_Graph_Whose_Remote_Differs_Is_Not_Pointed_At'Access,
         "A graph whose remote differs is not pointed at");
      Register_Routine
        (T,
         A_Branch_With_No_Graph_Is_Told_So_And_Where_Its_Siblings_Are'Access,
         "A branch with no graph is told so, and where its siblings are");
      Register_Routine
        (T, The_Other_Namespaces_Are_Listed_By_Name_And_Remote'Access,
         "The other namespaces are listed by name and remote");
      Register_Routine
        (T,
         The_Standing_Instructions_Come_From_The_First_Root_That_Has_Them'
           Access,
         "The standing instructions come from the first root that has them");
      Register_Routine
        (T,
         Nothing_Is_Said_Outside_A_Repository_With_Nothing_Configured'Access,
         "Nothing is said outside a repository with nothing configured");
   end Register_Tests;

end Synapse.Hooks.Session_Start.Tests;
