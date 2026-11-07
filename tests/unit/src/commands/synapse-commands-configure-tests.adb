with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;

package body Synapse.Commands.Configure.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure Put (File, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (File));
      Synapse.Adapters.File_Bytes.Write (File, Text);
   end Put;

   function Read (File : String) return String is
     (Synapse.Adapters.File_Bytes.Read (File, 1_000_000));

   function Exists (File : String) return Boolean is
     (Ada.Directories.Exists (File));

   Hook_Template : constant String :=
     "{""hooks"":{""SessionStart"":[{""hooks"":[{""type"":""command"","
     & """command"":""synapse-hook session-start""}]}],"
     & """PostToolUse"":[{""matcher"":""Write|Edit"",""hooks"":[{""type"":"
     & """command"",""command"":""synapse-hook staleness""}]}]}}";

   Plugin_Template : constant String :=
     "const HOOK_BIN = process.env.X || ""__SYNAPSE_HOOK_BIN__""" & LF;

   --  A machine: a home, the content that is installed, and a folder with this
   --  program and its hook program in it.
   subtype World is Scratch;

   function Home (W : World) return String is (Path (W, "home"));
   function Content (W : World) return String is (Path (W, "content"));
   function Bin (W : World) return String is (Path (W, "bin"));
   function Hook (W : World) return String is (Bin (W) & "/synapse-hook");

   function Make_World return World is
   begin
      return W : constant World := Make do
         Ada.Directories.Create_Path (Home (W));
         Put (Content (W) & "/skills/alpha/SKILL.md", "alpha");
         Put (Content (W) & "/skills/beta/SKILL.md", "beta");
         Put (Content (W) & "/commands/one.md", "one");
         Put (Content (W) & "/commands/two.md", "two");
         Put (Content (W) & "/commands/notes.txt", "not a command");
         Put (Content (W) & "/harness/claude/hooks.json", Hook_Template);
         Put (Content (W) & "/harness/codex/hooks.json", Hook_Template);
         Put (Content (W) & "/harness/codex/skills/gamma/SKILL.md", "gamma");
         Put
           (Content (W) & "/harness/opencode/plugin/synapse.js",
            Plugin_Template);
         Put
           (Content (W) & "/synapse.conf.template",
            "SYNAPSE_VAULT_DIR=" & LF);
         Put (Bin (W) & "/synapse", "");
         Put (Hook (W), "");
      end return;
   end Make_World;

   --  Runs `configure Harness` in W's machine, and says what it returned.
   function Configure
     (W : World; Harness : String; Out_Text, Err_Text : out
        Ada.Strings.Unbounded.Unbounded_String) return Exit_Code
   is
      F : aliased Synapse.Test_Environment.Fixture;
   begin
      F.Vars.Set ("HOME", Home (W));
      F.Vars.Set ("SYNAPSE_CONTENT_ROOT", Content (W));
      declare
         Environment_Of_W : constant Synapse.Commands.Environment :=
           (Console    => F.Console'Access, Vars => F.Vars'Access,
            Runner     => F.Runner'Access, Clock => F.Clock'Access,
            Extractors => F.Extractors'Access,
            Argv0      =>
              Ada.Strings.Unbounded.To_Unbounded_String (Bin (W) & "/synapse"));
         Code : constant Exit_Code :=
           Run (Environment_Of_W, Synapse.Test_Environment.Args (Harness));
      begin
         Out_Text := Ada.Strings.Unbounded.To_Unbounded_String (F.Console.Out_Text);
         Err_Text := Ada.Strings.Unbounded.To_Unbounded_String (F.Console.Err_Text);
         return Code;
      end;
   end Configure;

   function Configure (W : World; Harness : String) return Exit_Code is
      Out_Text, Err_Text : Ada.Strings.Unbounded.Unbounded_String;
   begin
      return Configure (W, Harness, Out_Text, Err_Text);
   end Configure;

   procedure Claude_Gets_Skills_Commands_Hooks_And_The_Content_Root
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant World := Make_World;
      Said, Complained : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Assert
        (Configure (W, "claude", Said, Complained) = 0,
         "it succeeds: " & Ada.Strings.Unbounded.To_String (Complained));
      Assert
        (Read (Home (W) & "/.claude/skills/alpha/SKILL.md") = "alpha"
         and then Read (Home (W) & "/.claude/skills/beta/SKILL.md") = "beta",
         "each skill");
      Assert
        (Read (Home (W) & "/.claude/commands/one.md") = "one"
         and then not Exists (Home (W) & "/.claude/commands/notes.txt"),
         "the commands, and only the .md files");
      Assert
        (Read (Home (W) & "/.claude/skills/.synapse-managed.json") =
         "[" & LF & "  ""alpha""," & LF & "  ""beta""" & LF & "]" & LF,
         "a manifest of the skills");
      declare
         Settings : constant String := Read (Home (W) & "/.claude/settings.json");
      begin
         Assert
           (Has (Settings, """command"": """ & Hook (W) & " session-start"""),
            "the hook program's path replaces its bare name: " & Settings);
         Assert
           (Has (Settings, """matcher"": ""Write|Edit"""),
            "a matcher is kept");
         Assert
           (Has
              (Settings,
               """env"": {" & LF & "    ""SYNAPSE_CONTENT_ROOT"": """
               & Content (W) & """" & LF & "  }"),
            "the content root is in the env");
      end;
      Assert
        (Has (Ada.Strings.Unbounded.To_String (Said), "installed 2 skills, 2 commands to ~/.claude")
         and then Has (Ada.Strings.Unbounded.To_String (Said), "restart Claude Code"),
         "it says what it did");
      Remove (W);
   exception
      when others =>
         Remove (W);
         raise;
   end Claude_Gets_Skills_Commands_Hooks_And_The_Content_Root;

   procedure Hooks_Are_Merged_Into_What_Is_There_And_A_Rerun_Adds_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant World := Make_World;
      Settings : constant String := Home (W) & "/.claude/settings.json";
      Original : constant String :=
        "{""theme"":""dark"",""hooks"":{""SessionStart"":[{""hooks"":"
        & "[{""type"":""command"",""command"":""other-tool start""}]},"
        & "{""hooks"":[{""type"":""command"",""command"":"
        & """/old/place/synapse-hook session-start""}]}],""Stop"":[]},"
        & """env"":{""FOO"":""1""}}";
   begin
      Put (Settings, Original);
      Assert (Configure (W, "claude") = 0, "first run");
      declare
         First : constant String := Read (Settings);
      begin
         Assert (Has (First, """theme"": ""dark"""), "other settings stay");
         Assert (Has (First, """FOO"": ""1"""), "and other variables");
         Assert (Has (First, "other-tool start"), "another tool's hook stays");
         Assert
           (not Has (First, "/old/place/synapse-hook"),
            "a group an earlier run wrote, at another path, is replaced");
         Assert (Read (Settings & ".bak") = Original, "a copy is kept");
         Assert (Configure (W, "claude") = 0, "second run");
         Assert (Read (Settings) = First, "a second run changes nothing");
      end;
      Remove (W);
   exception
      when others =>
         Remove (W);
         raise;
   end Hooks_Are_Merged_Into_What_Is_There_And_A_Rerun_Adds_Nothing;

   procedure Settings_That_Cannot_Be_Merged_Into_Stop_The_Run_Before_It_Writes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant World := Make_World;
      Settings : constant String := Home (W) & "/.claude/settings.json";
      Said, Complained : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Put (Settings, "{ not json");
      Assert
        (Configure (W, "claude", Said, Complained) = 1
         and then Has
           (Ada.Strings.Unbounded.To_String (Complained), "has invalid JSON"),
         "it says so: " & Ada.Strings.Unbounded.To_String (Complained));
      Assert
        (Read (Settings) = "{ not json"
         and then not Exists (Settings & ".bak")
         and then not Exists (Home (W) & "/.claude/skills"),
         "and has written nothing");
      Put (Settings, "[1]");
      Assert (Configure (W, "claude") = 1, "a list is not settings");
      Put (Settings, "{""hooks"":[]}");
      Assert (Configure (W, "claude") = 1, "hooks that are not an object");
      Put (Settings, "{""env"":3}");
      Assert (Configure (W, "claude") = 1, "an env that is not an object");
      Remove (W);
   exception
      when others =>
         Remove (W);
         raise;
   end Settings_That_Cannot_Be_Merged_Into_Stop_The_Run_Before_It_Writes;

   procedure A_Skill_No_Longer_Shipped_Is_Removed_And_Others_Stay
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant World := Make_World;
      Skills : constant String := Home (W) & "/.claude/skills";
   begin
      Put (Skills & "/mine/SKILL.md", "the user's own");
      Put (Skills & "/gone/SKILL.md", "an old one");
      Put (Skills & "/.synapse-managed.json", "[""alpha"",""gone"",""../x"","""","".""]");
      Put (Home (W) & "/.claude/x/keep.txt", "outside the folder");
      Assert (Configure (W, "claude") = 0, "it succeeds");
      Assert
        (not Exists (Skills & "/gone")
         and then Exists (Skills & "/mine/SKILL.md")
         and then Exists (Home (W) & "/.claude/x/keep.txt"),
         "what was listed and is not shipped goes; the rest is left");
      Remove (W);
   exception
      when others =>
         Remove (W);
         raise;
   end A_Skill_No_Longer_Shipped_Is_Removed_And_Others_Stay;

   procedure Codex_Gets_Hooks_And_Both_Kinds_Of_Skill
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant World := Make_World;
      Hooks : constant String := Home (W) & "/.codex/hooks.json";
   begin
      Put
        (Hooks,
         "{""hooks"":{""SessionStart"":[{""hooks"":[{""type"":""command"","
         & """command"":""keep-me""}]}]}}");
      Assert (Configure (W, "codex") = 0, "it succeeds");
      Assert
        (Has (Read (Hooks), "keep-me")
         and then Has (Read (Hooks), Hook (W) & " staleness"),
         "hooks merged into the file");
      Assert (Exists (Hooks & ".bak"), "with a copy kept");
      Assert
        (Read (Home (W) & "/.codex/skills/alpha/SKILL.md") = "alpha"
         and then Read (Home (W) & "/.codex/skills/gamma/SKILL.md") = "gamma",
         "the shared skills and the ones for Codex");
      Assert
        (Has
           (Read (Home (W) & "/.codex/skills/.synapse-managed.json"),
            """gamma"""),
         "both in the manifest");
      Remove (W);
   exception
      when others =>
         Remove (W);
         raise;
   end Codex_Gets_Hooks_And_Both_Kinds_Of_Skill;

   procedure OpenCode_Gets_A_Plugin_With_The_Hook_Path_And_Its_Folders
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant World := Make_World;
      Folder : constant String := Home (W) & "/.config/opencode";
   begin
      Assert (Configure (W, "opencode") = 0, "it succeeds");
      Assert
        (Read (Folder & "/plugin/synapse.js") =
         "const HOOK_BIN = process.env.X || """ & Hook (W) & """" & LF,
         "the path is in the plugin as a string: "
         & Read (Folder & "/plugin/synapse.js"));
      Assert
        (Exists (Folder & "/skill/alpha/SKILL.md")
         and then Exists (Folder & "/command/one.md"),
         "skills in skill/ and commands in command/");
      Assert
        (not Exists (Home (W) & "/.claude/skills")
         and then not Exists (Home (W) & "/.claude/settings.json"),
         "and no skills or settings for Claude");
      Remove (W);
   exception
      when others =>
         Remove (W);
         raise;
   end OpenCode_Gets_A_Plugin_With_The_Hook_Path_And_Its_Folders;

   procedure A_Conf_Is_Made_From_Its_Template_Once
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant World := Make_World;
      Said, Complained : Ada.Strings.Unbounded.Unbounded_String;
      Conf : constant String := Home (W) & "/.claude/synapse.conf";
   begin
      Assert (Configure (W, "claude", Said, Complained) = 0, "first");
      Assert
        (Read (Conf) = "SYNAPSE_VAULT_DIR=" & LF
         and then Has (Ada.Strings.Unbounded.To_String (Said), "wrote " & Conf),
         "a conf where the tiers say, with the template's text");
      Put (Conf, "SYNAPSE_VAULT_DIR=/mine" & LF);
      Assert (Configure (W, "claude", Said, Complained) = 0, "second");
      Assert
        (Read (Conf) = "SYNAPSE_VAULT_DIR=/mine" & LF
         and then not Has (Ada.Strings.Unbounded.To_String (Said), "wrote "),
         "one that is there is never replaced");
      Remove (W);
   exception
      when others =>
         Remove (W);
         raise;
   end A_Conf_Is_Made_From_Its_Template_Once;

   procedure What_Is_Missing_Is_Said_Before_Anything_Is_Written
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant World := Make_World;
      Said, Complained : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Ada.Directories.Delete_File (Hook (W));
      Assert
        (Configure (W, "claude", Said, Complained) = 1
         and then Has
           (Ada.Strings.Unbounded.To_String (Complained), "synapse-hook"),
         "no hook program: " & Ada.Strings.Unbounded.To_String (Complained));
      Put (Hook (W), "");
      Ada.Directories.Delete_Tree (Content (W) & "/skills");
      Assert
        (Configure (W, "claude", Said, Complained) = 1
         and then Has
           (Ada.Strings.Unbounded.To_String (Complained),
            "SYNAPSE_CONTENT_ROOT"),
         "no content: " & Ada.Strings.Unbounded.To_String (Complained));
      Assert
        (not Exists (Home (W) & "/.claude"), "nothing was written");
      Remove (W);
   exception
      when others =>
         Remove (W);
         raise;
   end What_Is_Missing_Is_Said_Before_Anything_Is_Written;

   procedure A_Bad_Argument_Is_A_Usage_Error_And_Help_Is_Not
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant World := Make_World;
      Said, Complained : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Assert (Configure (W, "cursor") = 2, "an unknown harness");
      Assert (Configure (W, "") = 2, "no harness");
      Assert (Configure (W, "--help", Said, Complained) = 0, "help");
      Assert
        (Has (Ada.Strings.Unbounded.To_String (Said), "usage: synapse configure"),
         "it prints the usage");
      Assert (not Exists (Home (W) & "/.claude"), "and writes nothing");
      Remove (W);
   exception
      when others =>
         Remove (W);
         raise;
   end A_Bad_Argument_Is_A_Usage_Error_And_Help_Is_Not;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Configure");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Claude_Gets_Skills_Commands_Hooks_And_The_Content_Root'Access,
         "Claude gets skills, commands, hooks and the content root");
      Register_Routine
        (T,
         Hooks_Are_Merged_Into_What_Is_There_And_A_Rerun_Adds_Nothing'Access,
         "Hooks are merged into what is there and a rerun adds nothing");
      Register_Routine
        (T,
         Settings_That_Cannot_Be_Merged_Into_Stop_The_Run_Before_It_Writes'Access,
         "Settings that cannot be merged into stop the run before it writes");
      Register_Routine
        (T, A_Skill_No_Longer_Shipped_Is_Removed_And_Others_Stay'Access,
         "A skill no longer shipped is removed and others stay");
      Register_Routine
        (T, Codex_Gets_Hooks_And_Both_Kinds_Of_Skill'Access,
         "Codex gets hooks and both kinds of skill");
      Register_Routine
        (T, OpenCode_Gets_A_Plugin_With_The_Hook_Path_And_Its_Folders'Access,
         "OpenCode gets a plugin with the hook path and its folders");
      Register_Routine
        (T, A_Conf_Is_Made_From_Its_Template_Once'Access,
         "A conf is made from its template once");
      Register_Routine
        (T, What_Is_Missing_Is_Said_Before_Anything_Is_Written'Access,
         "What is missing is said before anything is written");
      Register_Routine
        (T, A_Bad_Argument_Is_A_Usage_Error_And_Help_Is_Not'Access,
         "A bad argument is a usage error and help is not");
   end Register_Tests;

end Synapse.Commands.Configure.Tests;
