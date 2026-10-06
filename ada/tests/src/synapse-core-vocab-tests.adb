with AUnit.Assertions;

package body Synapse.Core.Vocab.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure A_Group_Is_The_First_Directories_And_Never_The_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Group_Of ("src/main/java/Foo.ext", 2) = "src/main", "depth 2");
      Assert (Group_Of ("src/main/java/Foo.ext", 1) = "src", "depth 1");
      Assert
        (Group_Of ("src/Foo.ext", 2) = "src",
         "shallower than the depth: the prefix it has");
      Assert (Group_Of ("a/b/c/d/e.ext", 3) = "a/b/c", "depth 3");
      Assert (Group_Of ("a/b/c.ext", 99) = "a/b", "deeper than the path");
   end A_Group_Is_The_First_Directories_And_Never_The_File;

   procedure A_File_At_The_Root_Is_Named_Not_Dropped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Group_Of ("README.md", 2) = "(repo root)", "readme");
      Assert (Group_Of ("Makefile", 1) = "(repo root)", "no extension");
      Assert (Group_Of ("c.ext", 99) = "(repo root)", "any depth");
      Assert
        (Group_Of ("src/a.ext", 0) = Repo_Root_Group,
         "depth zero groups nothing");
      Assert (Group_Of ("", 2) = Repo_Root_Group, "an empty path");
   end A_File_At_The_Root_Is_Named_Not_Dropped;

   procedure The_Artifact_Kind_Is_The_Extension_Or_The_File_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Artifact_Of ("src/main/java/Foo.ext") = "ext", "extension");
      Assert (Artifact_Of ("db/Schema.SQL") = "sql", "lowercased");
      Assert
        (Artifact_Of ("widget/src/dune") = "dune",
         "no dot: the file name stands");
      Assert (Artifact_Of ("Makefile") = "makefile", "no directory");
      Assert
        (Artifact_Of (".gitignore") = "gitignore",
         "a leading dot is an extension");
      Assert (Artifact_Of ("weird.") = "weird.", "nothing after the dot");
      Assert
        (Artifact_Of ("app/bundle.min.ext") = "ext",
         "only the last dot counts");
      Assert
        (Artifact_Of ("a.b/c") = "c",
         "a directory's dots are not the " & "file's");
      Assert (Artifact_Of ("") = "", "empty");
      Assert (Artifact_Of ("dir/") = "", "a path that ends in a slash");
   end The_Artifact_Kind_Is_The_Extension_Or_The_File_Name;

   procedure Only_Ascii_Letters_Are_Lowercased (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Accented : constant String :=
        "f." & Character'Val (16#C3#) & Character'Val (16#80#);
   begin
      Assert
        (Artifact_Of (Accented) =
         Character'Val (16#C3#) & Character'Val (16#80#),
         "bytes from 16#80# up are untouched");
   end Only_Ascii_Letters_Are_Lowercased;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Vocab");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Group_Is_The_First_Directories_And_Never_The_File'Access,
         "A group is the first directories and never the file");
      Register_Routine
        (T, A_File_At_The_Root_Is_Named_Not_Dropped'Access,
         "A file at the root is named, not dropped");
      Register_Routine
        (T, The_Artifact_Kind_Is_The_Extension_Or_The_File_Name'Access,
         "The artifact kind is the extension or the file name");
      Register_Routine
        (T, Only_Ascii_Letters_Are_Lowercased'Access,
         "Only ASCII letters are lowercased");
   end Register_Tests;

end Synapse.Core.Vocab.Tests;
