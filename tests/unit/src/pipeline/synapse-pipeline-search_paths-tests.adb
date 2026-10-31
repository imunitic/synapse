with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

with AUnit.Assertions;

with Synapse.Adapters.Fake_Variables;

package body Synapse.Pipeline.Search_Paths.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   Sep : constant Character := GNAT.OS_Lib.Path_Separator;

   function Path_Of (V : Root_Vectors.Vector; I : Positive) return String is
     (To_String (V (I).Path));

   procedure The_Configuration_Directory_Prefers_XDG
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      Assert (Config_Directory (V) = "", "no home, no directory");
      V.Set ("HOME", "/home/u");
      Assert
        (Config_Directory (V) = "/home/u/.config/synapse-pipeline",
         "under the home");
      V.Set ("XDG_CONFIG_HOME", "/xdg");
      Assert
        (Config_Directory (V) = "/xdg/synapse-pipeline", "under XDG");
      V.Set ("XDG_CONFIG_HOME", "");
      Assert
        (Config_Directory (V) = "/home/u/.config/synapse-pipeline",
         "an empty XDG_CONFIG_HOME is not set");
   end The_Configuration_Directory_Prefers_XDG;

   procedure Definition_Roots_Are_The_Default_Then_The_Listed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      Assert (Definition_Roots (V).Is_Empty, "nothing to look in");
      V.Set ("HOME", "/h");
      declare
         R : constant Root_Vectors.Vector := Definition_Roots (V);
      begin
         Assert
           (Natural (R.Length) = 1
            and then Path_Of (R, 1) = "/h/.config/synapse-pipeline"
            and then not R (1).Required,
            "the default, which need not exist");
      end;
      V.Set (Path_Variable, "/a" & Sep & Sep & "/b/c" & Sep);
      declare
         R : constant Root_Vectors.Vector := Definition_Roots (V);
      begin
         Assert (Natural (R.Length) = 3, "the default and two listed");
         Assert
           (Path_Of (R, 2) = "/a" and then Path_Of (R, 3) = "/b/c"
            and then R (2).Required and then R (3).Required,
            "in order, empty entries dropped, and required");
      end;
   end Definition_Roots_Are_The_Default_Then_The_Listed;

   procedure Skill_Roots_Start_With_The_User_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      Assert (Skill_Roots (V).Is_Empty, "no home, no root");
      V.Set ("XDG_CONFIG_HOME", "/x");
      declare
         R : constant Root_Vectors.Vector := Skill_Roots (V);
      begin
         Assert
           (Natural (R.Length) = 1
            and then Path_Of (R, 1) = "/x/synapse-pipeline/skills"
            and then not R (1).Required,
            "the user's skills directory");
      end;
   end Skill_Roots_Start_With_The_User_Directory;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Search_Paths");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Configuration_Directory_Prefers_XDG'Access,
         "The configuration directory prefers XDG");
      Register_Routine
        (T, Definition_Roots_Are_The_Default_Then_The_Listed'Access,
         "Definition roots are the default then the listed");
      Register_Routine
        (T, Skill_Roots_Start_With_The_User_Directory'Access,
         "Skill roots start with the user directory");
   end Register_Tests;

end Synapse.Pipeline.Search_Paths.Tests;
