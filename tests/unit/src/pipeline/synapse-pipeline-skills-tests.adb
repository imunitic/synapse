with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Fake_Files;

package body Synapse.Pipeline.Skills.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Root (Path : String) return Search_Paths.Root is
     (Path => To_Unbounded_String (Path), Required => False);

   procedure Names_Follow_The_Specification (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Valid_Name ("a"), "a");
      Assert (Is_Valid_Name ("review-code"), "review-code");
      Assert (Is_Valid_Name ("x1-2"), "x1-2");
      Assert (Is_Valid_Name ("0"), "0");
      Assert (Is_Valid_Name ("a-b-c"), "a-b-c");
      Assert (not Is_Valid_Name (""), "empty");
      Assert (not Is_Valid_Name ("-a"), "a hyphen first");
      Assert (not Is_Valid_Name ("a-"), "a hyphen last");
      Assert (not Is_Valid_Name ("a--b"), "two hyphens");
      Assert (not Is_Valid_Name ("A"), "a capital");
      Assert (not Is_Valid_Name ("a_b"), "an underscore");
      Assert (not Is_Valid_Name ("a b"), "a space");
      Assert (not Is_Valid_Name ("a.b"), "a dot");
      Assert (Is_Valid_Name ([1 .. 64 => 'a']), "64 characters");
      Assert (not Is_Valid_Name ([1 .. 65 => 'a']), "65 characters");
   end Names_Follow_The_Specification;

   procedure The_First_Root_Holding_A_Skill_Wins (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F     : Fake_Files.Fake_Files;
      Roots : Search_Paths.Root_Vectors.Vector;
   begin
      F.Add_File ("/user/review-code/SKILL.md", "user");
      F.Add_File ("/harness/review-code/SKILL.md", "harness");
      F.Add_File ("/harness/only-here/SKILL.md", "harness");
      F.Add_File ("/user/no-skill-file/notes.md", "not a skill");
      Roots.Append (Root ("/missing"));
      Roots.Append (Root ("/user"));
      Roots.Append (Root ("/harness/"));
      Assert
        (Find (F, Roots, "review-code").Found
         and then To_String (Find (F, Roots, "review-code").Value) =
                  "/user/review-code",
         "the earlier root, a missing root skipped");
      Assert
        (To_String (Find (F, Roots, "only-here").Value) =
         "/harness/only-here",
         "a later root, with a trailing slash");
      Assert
        (not Find (F, Roots, "no-skill-file").Found
         and then not Find (F, Roots, "absent").Found,
         "a directory without SKILL.md is not a skill");
      Assert
        (Searched (Roots) = "/missing, /user, /harness/", "the roots");
      Assert (Searched (Search_Paths.Root_Vectors.Empty_Vector) = "", "none");
   end The_First_Root_Holding_A_Skill_Wins;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Skills");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Names_Follow_The_Specification'Access,
         "Names follow the specification");
      Register_Routine
        (T, The_First_Root_Holding_A_Skill_Wins'Access,
         "The first root holding a skill wins");
   end Register_Tests;

end Synapse.Pipeline.Skills.Tests;
