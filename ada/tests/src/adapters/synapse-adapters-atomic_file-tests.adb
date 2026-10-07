with Ada.Directories;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Atomic_File.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure A_File_Is_Written_Whole_And_Replaced_Whole
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "deep/er/file.bin");
   begin
      Write (P, "first");
      Assert
        (File_Bytes.Read (P, 100) = "first", "created, with its directory");
      Write (P, "second and longer");
      Assert (File_Bytes.Read (P, 100) = "second and longer", "replaced");
      Write (P, "");
      Assert (File_Bytes.Read (P, 100) = "", "replaced by nothing");
      Assert
        (not Ada.Directories.Exists (P & ".tmp"), "no temporary file is left");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_File_Is_Written_Whole_And_Replaced_Whole;

   procedure A_Path_With_No_Directory_Part_Is_Written_Where_It_Is
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "plain.bin");
   begin
      Write (P, "x");
      Assert (File_Bytes.Read (P, 10) = "x", "written");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Path_With_No_Directory_Part_Is_Written_Where_It_Is;

   procedure A_Failed_Write_Leaves_The_Old_File_And_No_Temporary
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      P      : constant String  := Path (Dir, "target");
      Raised : Boolean          := False;
   begin
      --  A directory where the file should go cannot be replaced by a file.
      Ada.Directories.Create_Path (P);
      begin
         Write (P, "x");
      exception
         when others =>
            Raised := True;
      end;
      Assert (Raised, "the write fails");
      Assert
        (Ada.Directories.Exists (P)
         and then not Ada.Directories.Exists (P & ".tmp"),
         "what was there stays and no temporary file is left");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Failed_Write_Leaves_The_Old_File_And_No_Temporary;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Atomic_File");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_File_Is_Written_Whole_And_Replaced_Whole'Access,
         "A file is written whole and replaced whole");
      Register_Routine
        (T, A_Path_With_No_Directory_Part_Is_Written_Where_It_Is'Access,
         "A path with no directory part is written where it is");
      Register_Routine
        (T, A_Failed_Write_Leaves_The_Old_File_And_No_Temporary'Access,
         "A failed write leaves the old file and no temporary");
   end Register_Tests;

end Synapse.Adapters.Atomic_File.Tests;
