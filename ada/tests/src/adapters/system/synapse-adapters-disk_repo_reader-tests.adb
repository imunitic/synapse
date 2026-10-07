with Ada.Directories;

with AUnit.Assertions;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.Deps;
with Synapse.Core.Namespace;
with Synapse.Core.Text_Lists;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Disk_Repo_Reader.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   procedure Files_Are_Read_Relative_To_The_Root (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      R   : Reader           := Create (Path (Dir));
   begin
      Ada.Directories.Create_Path (Path (Dir, "pkg"));
      File_Bytes.Write (Path (Dir, "pkg/a.txt"), "hello");
      declare
         Found : constant Ports.Repo_Reader.Maybe_Content :=
           Read (R, "pkg/a.txt");
      begin
         Assert
           (Found.Found and then To_String (Found.Value) = "hello",
            "the content");
      end;
      Assert (not Read (R, "pkg/missing.txt").Found, "a missing file");
      Assert (not Read (R, "pkg").Found, "a directory");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Files_Are_Read_Relative_To_The_Root;

   procedure A_File_Over_The_Limit_Is_Not_Read (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      R   : Reader           := Create (Path (Dir));
   begin
      File_Bytes.Write (Path (Dir, "ok.bin"), [1 .. Largest_File => 'x']);
      File_Bytes.Write (Path (Dir, "big.bin"), [1 .. Largest_File + 1 => 'x']);
      Assert (Read (R, "ok.bin").Found, "exactly the limit");
      Assert (not Read (R, "big.bin").Found, "one byte over");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_File_Over_The_Limit_Is_Not_Read;

   procedure Rules_Run_Over_A_Real_Directory (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      R    : Reader           := Create (Path (Dir));
      Kept : Core.Text_Lists.Vector;
   begin
      Ada.Directories.Create_Path (Path (Dir, "widget/src"));
      File_Bytes.Write
        (Path (Dir, "widget/src/build.deps"),
         "name widget" & LF & "depends gadget str" & LF);
      File_Bytes.Write (Path (Dir, "widget/src/main.xx"), "run" & LF);
      Kept.Append (To_Unbounded_String ("widget/src/build.deps"));
      Kept.Append (To_Unbounded_String ("widget/src/main.xx"));
      declare
         Namespaces : constant Core.Namespace.Row_Vectors.Vector :=
           Core.Namespace.Compute_Per_File
             (R, Kept,
              Core.Namespace.Parse
                ("{""xx"": {""kind"": ""build-file""," &
                 " ""file"": ""build.deps"", ""prefix"": ""name ""}}"));
         Libraries  : constant Core.Deps.Row_Vectors.Vector      :=
           Core.Deps.Compute
             (R, Kept,
              Core.Namespace.Parse
                ("{""xx"": {""kind"": ""build-file""," &
                 " ""file"": ""build.deps""," &
                 " ""prefix"": ""depends ""}}"));
      begin
         Assert
           (Natural (Namespaces.Length) = 1
            and then To_String (Namespaces (1).Namespace) = "widget",
            "the namespace of a file");
         Assert
           (Natural (Libraries.Length) = 2
            and then To_String (Libraries (2).Library) = "str",
            "its two libraries");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rules_Run_Over_A_Real_Directory;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Disk_Repo_Reader");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Files_Are_Read_Relative_To_The_Root'Access,
         "Files are read relative to the root");
      Register_Routine
        (T, A_File_Over_The_Limit_Is_Not_Read'Access,
         "A file over the limit is not read");
      Register_Routine
        (T, Rules_Run_Over_A_Real_Directory'Access,
         "Rules run over a real directory");
   end Register_Tests;

end Synapse.Adapters.Disk_Repo_Reader.Tests;
