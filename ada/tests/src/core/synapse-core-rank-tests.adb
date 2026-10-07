with Ada.Numerics.Discrete_Random;

with AUnit.Assertions;

package body Synapse.Core.Rank.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Stem_Of (Path : String) return String is
     (To_String (Key_Of (Path).Stem));

   function Module_Of (Path : String) return String is
     (To_String (Key_Of (Path).Module));

   procedure A_Test_Directory_Segment_Is_Matched_Whole
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_Test ("test/Foo.ext"), "test/Foo.ext");
      Assert (Is_Test ("src/test/java/Foo.ext"), "src/test/java/Foo.ext");
      Assert (Is_Test ("spec/thing.ext"), "spec/thing.ext");
      Assert (Is_Test ("app/__tests__/x.ext"), "app/__tests__/x.ext");
      Assert (Is_Test ("lib/testing/helper.ext"), "lib/testing/helper.ext");
      Assert (Is_Test ("a/specs/b.ext"), "a/specs/b.ext");
      Assert (Is_Test ("a/tests/b.ext"), "a/tests/b.ext");
      Assert (Is_Test ("test/runner"), "test/runner");
      Assert (not Is_Test ("testdata/fixture.bin"), "testdata/fixture.bin");
      Assert (not Is_Test ("src/testutil/Helper.ext"), "testutil");
      Assert (not Is_Test ("contest/Entry.ext"), "contest/Entry.ext");
      Assert (not Is_Test ("src/main/java/Foo.ext"), "src/main/java/Foo.ext");
      Assert (not Is_Test ("src/test"), "src/test");
      Assert (not Is_Test ("test"), "test");
   end A_Test_Directory_Segment_Is_Matched_Whole;

   procedure A_Capitalised_Suffix_Needs_A_Lowercase_Digit_Or_Dot_Before_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Is_Test ("src/FooTest.ext") and then Is_Test ("src/FooTests.ext")
         and then Is_Test ("src/FooSpec.ext")
         and then Is_Test ("src/Foo2Test.ext")
         and then Is_Test ("src/Foo.Tests.ext"),
         "the spellings");
      Assert
        (not Is_Test ("src/Latest.ext")
         and then not Is_Test ("src/Greatest.ext"),
         "a word that merely ends in test");
      Assert (not Is_Test ("src/Test.ext"), "nothing before the capital");
      Assert (not Is_Test ("src/FOOTest.ext"), "an uppercase letter before");
   end A_Capitalised_Suffix_Needs_A_Lowercase_Digit_Or_Dot_Before_It;

   procedure A_Separated_Suffix_Is_Matched_On_Dot_Underscore_And_Dash
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_Test ("src/foo.test.ext"), "dot");
      Assert (Is_Test ("src/foo_test.ext"), "underscore");
      Assert (Is_Test ("src/foo-spec.ext"), "dash");
      Assert (Is_Test ("src/foo.spec.ext"), "spec");
      Assert (Is_Test ("src/mymodule_tests.ext"), "plural");
      Assert (Is_Test ("src/_test.ext"), "a separator before the word");
      Assert (not Is_Test ("src/footest.ext"), "no separator");
      Assert (not Is_Test ("src/protest.ext"), "a word that ends in test");
      Assert (not Is_Test ("src/test.ext"), "the bare word");
   end A_Separated_Suffix_Is_Matched_On_Dot_Underscore_And_Dash;

   procedure A_Suite_Suffix_And_A_Test_Prefix_Count
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_Test ("src/mymodule_SUITE.ext"), "suite");
      Assert (not Is_Test ("src/_SUITE.ext"), "nothing before the suffix");
      Assert (Is_Test ("src/a_SUITE.ext"), "one character before the suffix");
      Assert (not Is_Test ("src/mymodule_suite.ext"), "case sensitive");
      Assert (Is_Test ("src/test_thing.ext"), "lowercase prefix");
      Assert (Is_Test ("src/Test_thing.ext"), "capitalised prefix");
      Assert
        (not Is_Test ("src/tested_thing.ext")
         and then not Is_Test ("src/attest_thing.ext"),
         "not a prefix");
   end A_Suite_Suffix_And_A_Test_Prefix_Count;

   procedure A_Name_With_No_Extension_Matches_No_File_Name_Rule
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Is_Test ("bin/footest") and then not Is_Test ("Makefile")
         and then not Is_Test ("bin/test_thing")
         and then not Is_Test ("bin/FooTest"),
         "no extension");
      Assert (not Is_Test (""), "empty");
   end A_Name_With_No_Extension_Matches_No_File_Name_Rule;

   procedure Key_Takes_The_Stem_And_The_First_Two_Directories
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Stem_Of ("core/src/main/Widget.ext") = "Widget"
         and then Module_Of ("core/src/main/Widget.ext") = "core/src",
         "deep");
      Assert
        (Stem_Of ("core/Widget.ext") = "Widget"
         and then Module_Of ("core/Widget.ext") = "core",
         "shallow");
      Assert (Module_Of ("Widget.ext") = Repo_Root_Module, "root");
      Assert (Stem_Of ("/a") = "a", "stem of an absolute path");
      Assert
        (Module_Of ("/a") = Repo_Root_Module, "no module named by nothing");
      Assert
        (Stem_Of ("a/b/Widget.decl.bak") = "Widget.decl",
         "only the final extension goes");
      Assert (Stem_Of ("a/b/Makefile") = "Makefile", "no extension");
      Assert (Stem_Of ("a/.hidden") = "", "a leading dot is an extension");
      Assert (To_String (Key_Of ("x/y.ext").Path) = "x/y.ext", "the path");
   end Key_Takes_The_Stem_And_The_First_Two_Directories;

   procedure A_Declaration_Consumes_By_Stem_Prefix_In_One_Module
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Decl : constant Key := Key_Of ("core/src/Widget.decl");
   begin
      Assert
        (Consumes (Decl, Key_Of ("core/src/WidgetHandler.ext")),
         "a longer stem");
      Assert (Consumes (Decl, Key_Of ("core/src/Widget.ext")), "equal");
      Assert
        (not Consumes
           (Key_Of ("core/src/WidgetHandler.decl"),
            Key_Of ("core/src/Widget.ext")),
         "the declaration's stem is the prefix, not the code's");
      Assert
        (not Consumes (Decl, Key_Of ("other/src/WidgetHandler.ext")),
         "another module");
      Assert (not Consumes (Decl, Key_Of ("core/src/Gadget.ext")), "other");
   end A_Declaration_Consumes_By_Stem_Prefix_In_One_Module;

   procedure A_Stem_Under_Three_Characters_Makes_No_Hop
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Consumes
           (Key_Of ("core/src/Id.decl"), Key_Of ("core/src/IdMaker.ext")),
         "two");
      Assert
        (Consumes
           (Key_Of ("core/src/Wdg.decl"), Key_Of ("core/src/WdgHandler.ext")),
         "three");
   end A_Stem_Under_Three_Characters_Makes_No_Hop;

   procedure Density_Normalises_By_Size (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Density (10, 2_000) > Density (40, 40_000),
         "the dense file outranks the generated table");
      Assert (abs (Density (40, 40_000) - 1.0) < 0.001, "one per kilobyte");
      Assert (abs (Density (10, 2_000) - 5.0) < 0.001, "five per kilobyte");
      Assert (Density (0, 1) = 0.0, "no definitions");
   end Density_Normalises_By_Size;

   subtype Letter is Character range 'a' .. 'z';

   package Letters is new Ada.Numerics.Discrete_Random (Letter);

   function Random_Word
     (G : Letters.Generator; Length : Positive) return String
   is
      Result : String (1 .. Length);
   begin
      for C of Result loop
         C := Letters.Random (G);
      end loop;
      return Result;
   end Random_Word;

   procedure A_Test_Suffix_Is_Caught_Whatever_The_Stem
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      G : Letters.Generator;
   begin
      Letters.Reset (G, 11);
      for Length in 1 .. 40 loop
         declare
            Word : constant String := Random_Word (G, Length);
         begin
            Assert (Is_Test ("src/" & Word & "_test.ext"), Word & "_test");
            Assert (Is_Test ("src/" & Word & ".spec.ext"), Word & ".spec");
            Assert (Is_Test ("src/" & Word & "Test.ext"), Word & "Test");
         end;
      end loop;
   end A_Test_Suffix_Is_Caught_Whatever_The_Stem;

   procedure A_Real_Prefix_In_The_Same_Module_Is_Always_Consumed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      G : Letters.Generator;
   begin
      Letters.Reset (G, 12);
      for Stem_Length in Min_Stem .. 20 loop
         for Suffix_Length in 0 .. 20 loop
            declare
               Stem   : constant String := Random_Word (G, Stem_Length);
               Suffix : constant String :=
                 (if Suffix_Length = 0 then ""
                  else Random_Word (G, Suffix_Length));
            begin
               Assert
                 (Consumes
                    (Key_Of ("core/src/" & Stem & ".decl"),
                     Key_Of ("core/src/" & Stem & Suffix & ".ext")),
                  Stem & " prefixes " & Stem & Suffix);
            end;
         end loop;
      end loop;
   end A_Real_Prefix_In_The_Same_Module_Is_Always_Consumed;

   procedure Key_Of_Keeps_The_Path_And_Never_Has_An_Empty_Module
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      subtype Path_Char is Character range '-' .. 'z';
      package Chars is new Ada.Numerics.Discrete_Random (Path_Char);
      G : Chars.Generator;
   begin
      Chars.Reset (G, 13);
      for Size in 1 .. 40 loop
         for Round in 1 .. 20 loop
            declare
               Path : String (1 .. Size);
            begin
               for C of Path loop
                  C := Chars.Random (G);
               end loop;
               Assert (To_String (Key_Of (Path).Path) = Path, "round trip");
               Assert (Length (Key_Of (Path).Module) > 0, "module: " & Path);
            end;
         end loop;
      end loop;
   end Key_Of_Keeps_The_Path_And_Never_Has_An_Empty_Module;

   procedure Density_Is_Monotonic_In_Definitions_And_Never_Negative
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      type Size_List is array (Positive range <>) of Positive;
      Sizes : constant Size_List := [1, 7, 999, 1_000, 123_456, 1_000_000_000];
      Previous : Long_Float         := -1.0;
   begin
      for Size of Sizes loop
         Previous := -1.0;
         for Definitions in 0 .. 50 loop
            declare
               D : constant Long_Float := Density (Definitions, Size);
            begin
               Assert
                 (D >= 0.0 and then D >= Previous,
                  "non-decreasing in definitions");
               Previous := D;
            end;
         end loop;
      end loop;
   end Density_Is_Monotonic_In_Definitions_And_Never_Negative;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Rank");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Test_Directory_Segment_Is_Matched_Whole'Access,
         "A test directory segment is matched whole");
      Register_Routine
        (T,
         A_Capitalised_Suffix_Needs_A_Lowercase_Digit_Or_Dot_Before_It'Access,
         "A capitalised suffix needs a lowercase, digit or dot before it");
      Register_Routine
        (T, A_Separated_Suffix_Is_Matched_On_Dot_Underscore_And_Dash'Access,
         "A separated suffix is matched on dot, underscore and dash");
      Register_Routine
        (T, A_Suite_Suffix_And_A_Test_Prefix_Count'Access,
         "A suite suffix and a test prefix count");
      Register_Routine
        (T, A_Name_With_No_Extension_Matches_No_File_Name_Rule'Access,
         "A name with no extension matches no file name rule");
      Register_Routine
        (T, Key_Takes_The_Stem_And_The_First_Two_Directories'Access,
         "Key takes the stem and the first two directories");
      Register_Routine
        (T, A_Declaration_Consumes_By_Stem_Prefix_In_One_Module'Access,
         "A declaration consumes a code file by stem prefix in one module");
      Register_Routine
        (T, A_Stem_Under_Three_Characters_Makes_No_Hop'Access,
         "A stem under three characters makes no hop");
      Register_Routine
        (T, Density_Normalises_By_Size'Access, "Density normalises by size");
      Register_Routine
        (T, A_Test_Suffix_Is_Caught_Whatever_The_Stem'Access,
         "A test suffix is caught whatever the stem");
      Register_Routine
        (T, A_Real_Prefix_In_The_Same_Module_Is_Always_Consumed'Access,
         "A real prefix in the same module is always consumed");
      Register_Routine
        (T, Key_Of_Keeps_The_Path_And_Never_Has_An_Empty_Module'Access,
         "Key_Of keeps the path and never has an empty module");
      Register_Routine
        (T, Density_Is_Monotonic_In_Definitions_And_Never_Negative'Access,
         "Density is monotonic in definitions and never negative");
   end Register_Tests;

end Synapse.Core.Rank.Tests;
