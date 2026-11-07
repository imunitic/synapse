with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Definitions;
with Synapse.Pipeline.Namespaces;
with Synapse.Pipeline.Search_Paths;
with Synapse.Test_Scratch;

package body Synapse.Pipeline.System_Files.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  Exactly the bytes of Content: Text_IO would add a line terminator.
   procedure Write (Path, Content : String) is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Path);
      String'Write (Ada.Streams.Stream_IO.Stream (File), Content);
      Ada.Streams.Stream_IO.Close (File);
   end Write;

   procedure Files_Are_Listed_And_Read (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : constant Synapse.Test_Scratch.Scratch := Synapse.Test_Scratch.Make;
      F : System_Files;
      Dir : constant String := Synapse.Test_Scratch.Path (S, "defs");
   begin
      Ada.Directories.Create_Directory (Dir);
      Ada.Directories.Create_Directory (Dir & "/sub");
      Write (Dir & "/B.synapse", "Agent B [];");
      Write (Dir & "/A.synapse", "Agent A [];");
      Write (Dir & "/notes.md", "text");
      Write (Dir & "/sub/C.synapse", "Agent C [];");

      Assert
        (F.Is_Directory (Dir)
         and then not F.Is_Directory (Dir & "/A.synapse"),
         "a directory");
      Assert (F.Is_File (Dir & "/A.synapse") and then not F.Is_File (Dir),
              "a file");
      Assert (not F.Is_File (Dir & "/none") and then not F.Is_Directory (""),
              "nothing there");
      declare
         Names : constant Synapse.Core.Text_Lists.Vector :=
           F.List (Dir, ".synapse");
      begin
         Assert
           (Natural (Names.Length) = 2
            and then To_String (Names (1)) = "A.synapse"
            and then To_String (Names (2)) = "B.synapse",
            "the two definition files, sorted, none from the subdirectory");
      end;
      Assert (F.List (Dir & "/none", ".synapse").Is_Empty, "no directory");
      Assert
        (F.Read (Dir & "/A.synapse").Found
         and then To_String (F.Read (Dir & "/A.synapse").Value) =
                  "Agent A [];",
         "its content");
      Assert (not F.Read (Dir & "/none").Found, "a missing file");
      Assert (not F.Read (Dir).Found, "a directory is not content");
      Synapse.Test_Scratch.Remove (S);
   end Files_Are_Listed_And_Read;

   procedure A_Tree_Is_Written_Copied_And_Removed (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : constant Synapse.Test_Scratch.Scratch := Synapse.Test_Scratch.Make;
      F : System_Files;
      Dir  : constant String := Synapse.Test_Scratch.Path (S, "skills");
      Dest : constant String := Synapse.Test_Scratch.Path (S, "out/skills/a");
      Done : Boolean;
   begin
      Ada.Directories.Create_Directory (Dir);
      Ada.Directories.Create_Directory (Dir & "/a");
      Ada.Directories.Create_Directory (Dir & "/a/deep");
      Ada.Directories.Create_Directory (Dir & "/b");
      Write (Dir & "/a/SKILL.md", "alpha");
      Write (Dir & "/a/deep/more.md", "deeper");
      Write (Dir & "/loose.md", "not a skill");

      declare
         Names : constant Synapse.Core.Text_Lists.Vector :=
           F.Subdirectories (Dir);
      begin
         Assert
           (Natural (Names.Length) = 2
            and then To_String (Names (1)) = "a"
            and then To_String (Names (2)) = "b",
            "the directories, sorted, without the files or . and ..");
      end;
      Assert (F.Subdirectories (Dir & "/none").Is_Empty, "no directory");

      F.Replace_Tree (Dir & "/a", Dest, Done);
      Assert (Done, "the copy was made, with the directories above it");
      Assert
        (To_String (F.Read (Dest & "/SKILL.md").Value) = "alpha"
         and then To_String (F.Read (Dest & "/deep/more.md").Value) =
                  "deeper",
         "with every file, in the folders it was in");

      Write (Dest & "/left-over.md", "old");
      F.Replace_Tree (Dir & "/a", Dest, Done);
      Assert
        (Done and then not F.Is_File (Dest & "/left-over.md"),
         "a second copy replaces the first whole");

      F.Replace_Tree (Dir & "/none", Dest, Done);
      Assert
        (not Done and then F.Is_File (Dest & "/SKILL.md"),
         "a source that is not there is a failure that changes nothing");

      F.Write (Dest & "/manifest.json", "[]", Done);
      Assert
        (Done and then To_String (F.Read (Dest & "/manifest.json").Value) =
                       "[]",
         "a file is written");
      F.Write (Synapse.Test_Scratch.Path (S, "new/dir/x.txt"), "x", Done);
      Assert (Done, "with the directories above it");
      F.Write (Dir & "/loose.md/under.txt", "x", Done);
      Assert (not Done, "but not under a file");

      F.Remove_Tree (Dest);
      Assert (not F.Is_Directory (Dest), "a directory goes with what is in it");
      F.Remove_Tree (Dir & "/loose.md");
      Assert (not F.Is_File (Dir & "/loose.md"), "so does a file");
      F.Remove_Tree (Dir & "/none");
      Synapse.Test_Scratch.Remove (S);
   end A_Tree_Is_Written_Copied_And_Removed;

   procedure A_File_Over_The_Limit_Is_Not_Read (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : constant Synapse.Test_Scratch.Scratch := Synapse.Test_Scratch.Make;
      F : System_Files;
      Big : constant String := Synapse.Test_Scratch.Path (S, "big.synapse");
   begin
      Write (Big, [1 .. File_System.Max_File_Size + 1 => 'x']);
      Assert (not F.Read (Big).Found, "one byte over the limit");
      Write (Big, [1 .. File_System.Max_File_Size => 'x']);
      Assert (F.Read (Big).Found, "exactly the limit");
      Synapse.Test_Scratch.Remove (S);
   end A_File_Over_The_Limit_Is_Not_Read;

   procedure Definitions_Load_From_A_Real_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S     : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      F     : System_Files;
      Dir   : constant String := Synapse.Test_Scratch.Path (S, "defs");
      Roots : Search_Paths.Root_Vectors.Vector;
   begin
      Ada.Directories.Create_Directory (Dir);
      Write (Dir & "/Reviewer.synapse", "Agent Reviewer [Prompt => ""x""];");
      Write
        (Dir & "/Develop.synapse",
         "Pipeline Develop { A [Agent => Reviewer]; }");
      Roots.Append
        (Search_Paths.Root'(Path => To_Unbounded_String (Dir),
                            Required => True));
      declare
         R : constant Definitions.Load_Report := Definitions.Load (F, Roots);
      begin
         Assert (R.Problems.Is_Empty, "loads without a problem");
         Assert
           (Namespaces.Count (R.Definitions) = 2, "two definitions");
      end;
      Synapse.Test_Scratch.Remove (S);
   end Definitions_Load_From_A_Real_Directory;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.System_Files");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Files_Are_Listed_And_Read'Access, "Files are listed and read");
      Register_Routine
        (T, A_Tree_Is_Written_Copied_And_Removed'Access,
         "A tree is written, copied and removed");
      Register_Routine
        (T, A_File_Over_The_Limit_Is_Not_Read'Access,
         "A file over the limit is not read");
      Register_Routine
        (T, Definitions_Load_From_A_Real_Directory'Access,
         "Definitions load from a real directory");
   end Register_Tests;

end Synapse.Pipeline.System_Files.Tests;
