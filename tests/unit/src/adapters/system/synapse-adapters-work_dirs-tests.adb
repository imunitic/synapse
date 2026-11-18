with Ada.Directories;

with AUnit.Assertions;

with Synapse.Adapters.Fake_Variables;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Work_Dirs.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   procedure The_Root_Is_Under_The_Home_Cache_When_Nothing_Names_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      Assert (Root (V) = "", "nothing without a home");
      V.Set ("HOME", "/home/u");
      Assert (Root (V) = "/home/u/.cache/synapse/work", "the default");
      V.Set ("SYNAPSE_WORK_DIR", "");
      Assert
        (Root (V) = "/home/u/.cache/synapse/work",
         "an empty variable names nothing");
   end The_Root_Is_Under_The_Home_Cache_When_Nothing_Names_It;

   procedure The_Variable_Names_The_Root (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", "/home/u");
      V.Set ("SYNAPSE_WORK_DIR", "/elsewhere");
      Assert (Root (V) = "/elsewhere", "the variable");
      declare
         Without_Home : Synapse.Adapters.Fake_Variables.Fake_Variables;
      begin
         Without_Home.Set ("SYNAPSE_WORK_DIR", "/only");
         Assert (Root (Without_Home) = "/only", "and it needs no home");
      end;
   end The_Variable_Names_The_Root;

   procedure The_Setting_Of_The_Configuration_Files_Names_It_Too
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", Path (Dir, "home"));
      Ada.Directories.Create_Path (Path (Dir, "home/.claude"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "home/.claude/synapse.conf"),
         "SYNAPSE_WORK_DIR=/from/the/file" & LF);
      Assert (Root (V) = "/from/the/file", "the file's setting");
      V.Set ("SYNAPSE_WORK_DIR", "/from/the/variable");
      Assert (Root (V) = "/from/the/variable", "a variable wins over it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Setting_Of_The_Configuration_Files_Names_It_Too;

   procedure A_Namespace_Is_A_Folder_Of_The_Root (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      Assert (Of_Namespace (V, "repo@main") = "", "nothing without a root");
      V.Set ("HOME", "/home/u");
      Assert
        (Of_Namespace (V, "repo@main") =
         "/home/u/.cache/synapse/work/repo@main",
         "in the default root");
      V.Set ("SYNAPSE_WORK_DIR", "/r");
      Assert (Of_Namespace (V, "repo@main") = "/r/repo@main", "in a named one");
   end A_Namespace_Is_A_Folder_Of_The_Root;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Work_Dirs");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Root_Is_Under_The_Home_Cache_When_Nothing_Names_It'Access,
         "The root is under the home cache when nothing names it");
      Register_Routine
        (T, The_Variable_Names_The_Root'Access, "The variable names the root");
      Register_Routine
        (T, The_Setting_Of_The_Configuration_Files_Names_It_Too'Access,
         "The setting of the configuration files names it too");
      Register_Routine
        (T, A_Namespace_Is_A_Folder_Of_The_Root'Access,
         "A namespace is a folder of the root");
   end Register_Tests;

end Synapse.Adapters.Work_Dirs.Tests;
