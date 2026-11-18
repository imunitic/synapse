with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Configure.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Skills   : constant String := "/pkg/skills";
   Claude   : constant String := "/home/me/.claude/skills";
   Manifest : constant String := Claude & "/.synapse-pipeline-managed.json";

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   --  A home, and a package with two skills, one of them with a file beside
   --  its SKILL.md in a folder of its own.
   procedure Set_Up (F : in out Fixture) is
   begin
      F.Base.Vars.Set ("HOME", "/home/me");
      F.Base.Vars.Set ("SYNAPSE_CONTENT_ROOT", "/pkg");
      F.Files.Add_File (Skills & "/alpha/SKILL.md", "alpha text");
      F.Files.Add_File (Skills & "/alpha/notes/more.md", "more");
      F.Files.Add_File (Skills & "/beta/SKILL.md", "beta text");
   end Set_Up;

   procedure Skills_Are_Copied_With_What_Is_Beside_Them
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("claude")) = 0, "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "installed 2 skills to " & Claude & LF,
         "it says what it did: " & F.Base.Console.Out_Text);
      Assert
        (F.Files.Files.Element (Claude & "/alpha/SKILL.md") = "alpha text"
         and then F.Files.Files.Element (Claude & "/alpha/notes/more.md") =
                  "more"
         and then F.Files.Files.Element (Claude & "/beta/SKILL.md") =
                  "beta text",
         "each skill is there with its files");
      Assert
        (F.Files.Files.Element (Manifest) =
         "[" & LF & "  ""alpha""," & LF & "  ""beta""" & LF & "]" & LF,
         "the manifest lists the names, as the setup script wrote it");
   end Skills_Are_Copied_With_What_Is_Beside_Them;

   procedure Each_Harness_Has_Its_Own_Folder (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("codex")) = 0, "codex");
      Assert (Run (Env (F), Args ("opencode")) = 0, "opencode");
      Assert
        (F.Files.Is_File ("/home/me/.codex/skills/alpha/SKILL.md"),
         "Codex reads ~/.codex/skills");
      Assert
        (F.Files.Is_File ("/home/me/.config/opencode/skill/alpha/SKILL.md"),
         "OpenCode reads ~/.config/opencode/skill");
      Assert
        (not F.Files.Is_Directory (Claude), "and Claude's is not made");
   end Each_Harness_Has_Its_Own_Folder;

   procedure A_Second_Run_Replaces_And_Does_Not_Add
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("claude")) = 0, "first");
      F.Files.Add_File (Claude & "/alpha/left-over.md", "from a hand edit");
      F.Files.Add_File (Skills & "/alpha/SKILL.md", "alpha changed");
      Assert (Run (Env (F), Args ("claude")) = 0, "second");
      Assert
        (F.Files.Files.Element (Claude & "/alpha/SKILL.md") = "alpha changed",
         "the text is the new one");
      Assert
        (not F.Files.Is_File (Claude & "/alpha/left-over.md"),
         "a skill is replaced whole, nothing of the old one stays");
   end A_Second_Run_Replaces_And_Does_Not_Add;

   procedure A_Skill_No_Longer_Shipped_Is_Removed_And_Others_Are_Kept
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File (Claude & "/mine/SKILL.md", "the user's own");
      F.Files.Add_File (Claude & "/gone/SKILL.md", "an old one");
      F.Files.Add_File (Manifest, "[""alpha"", ""gone""]");
      Assert (Run (Env (F), Args ("claude")) = 0, "it succeeds");
      Assert
        (not F.Files.Is_Directory (Claude & "/gone"),
         "what the manifest listed and is no longer shipped is removed");
      Assert
        (F.Files.Is_File (Claude & "/mine/SKILL.md"),
         "what the manifest never listed is not touched");
      Assert
        (not Has (F.Files.Files.Element (Manifest), "gone"),
         "and the manifest no longer lists it");
   end A_Skill_No_Longer_Shipped_Is_Removed_And_Others_Are_Kept;

   procedure A_Manifest_Cannot_Point_Outside_The_Folder
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File ("/home/me/.claude/precious.txt", "keep");
      F.Files.Add_File (Manifest, "["".."", ""../x"", ""a\b"", """", "".""]");
      Assert (Run (Env (F), Args ("claude")) = 0, "it succeeds");
      Assert
        (F.Files.Is_File ("/home/me/.claude/precious.txt"),
         "names that are not one folder of the skills folder are ignored");
   end A_Manifest_Cannot_Point_Outside_The_Folder;

   procedure A_Manifest_That_Is_Not_A_List_Is_Taken_As_Empty
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File (Claude & "/mine/SKILL.md", "the user's own");
      F.Files.Add_File (Manifest, "{""not"": ""a list""");
      Assert (Run (Env (F), Args ("claude")) = 0, "it succeeds");
      Assert
        (F.Files.Is_File (Claude & "/mine/SKILL.md"), "nothing is removed");
   end A_Manifest_That_Is_Not_A_List_Is_Taken_As_Empty;

   procedure Without_A_Home_Or_A_Package_It_Says_So
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Base.Vars.Set ("HOME", "");
      Assert
        (Run (Env (F), Args ("claude")) = 1
         and then Has (F.Base.Console.Err_Text, "no home directory"),
         "no home: " & F.Base.Console.Err_Text);
      F.Base.Vars.Set ("HOME", "/home/me");
      F.Base.Vars.Set ("SYNAPSE_CONTENT_ROOT", "/nowhere");
      Assert
        (Run (Env (F), Args ("claude")) = 1
         and then Has (F.Base.Console.Err_Text, "SYNAPSE_CONTENT_ROOT"),
         "no skills folder: " & F.Base.Console.Err_Text);
      Assert (not F.Files.Is_Directory (Claude), "nothing was made");
   end Without_A_Home_Or_A_Package_It_Says_So;

   procedure A_Bad_Argument_Is_A_Usage_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args) = 2, "no harness");
      Assert (Run (Env (F), Args ("cursor")) = 2, "an unknown harness");
      Assert (Run (Env (F), Args ("claude", "codex")) = 2, "two harnesses");
      Assert
        (not F.Files.Is_Directory ("/home/me/.claude"), "nothing was made");
   end A_Bad_Argument_Is_A_Usage_Error;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Configure");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Skills_Are_Copied_With_What_Is_Beside_Them'Access,
         "Skills are copied with what is beside them");
      Register_Routine
        (T, Each_Harness_Has_Its_Own_Folder'Access,
         "Each harness has its own folder");
      Register_Routine
        (T, A_Second_Run_Replaces_And_Does_Not_Add'Access,
         "A second run replaces and does not add");
      Register_Routine
        (T, A_Skill_No_Longer_Shipped_Is_Removed_And_Others_Are_Kept'Access,
         "A skill no longer shipped is removed and others are kept");
      Register_Routine
        (T, A_Manifest_Cannot_Point_Outside_The_Folder'Access,
         "A manifest cannot point outside the folder");
      Register_Routine
        (T, A_Manifest_That_Is_Not_A_List_Is_Taken_As_Empty'Access,
         "A manifest that is not a list is taken as empty");
      Register_Routine
        (T, Without_A_Home_Or_A_Package_It_Says_So'Access,
         "Without a home or a package it says so");
      Register_Routine
        (T, A_Bad_Argument_Is_A_Usage_Error'Access,
         "A bad argument is a usage error");
   end Register_Tests;

end Synapse.Pipeline.Commands.Configure.Tests;
