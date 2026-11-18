with Ada.Directories;
with Ada.Text_IO;

with AUnit.Assertions;

with GNAT.OS_Lib;

with Synapse.Pipeline.Socket_Folders;
with Synapse.Test_Scratch;

package body Synapse.Pipeline.Socket_Paths.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function On_Windows return Boolean is
     (GNAT.OS_Lib.Directory_Separator = '\');

   --  The first two are the published FNV-1a 64 test values. The third is
   --  the example the Rust and Node hosts of Synapse Desktop test against
   --  too, so that the three agree.
   procedure The_Hash_Is_Fnv1a_64 (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Fnv1a_64_Hex ("") = "cbf29ce484222325", "the empty text");
      Assert (Fnv1a_64_Hex ("a") = "af63dc4c8601ec8c", "one letter");
      Assert
        (Fnv1a_64_Hex ("/Users/example/.cache/synapse/work/pipelines/probe1")
         = "04096b4c0fbf6a6c",
         "the example the desktop hosts share");
   end The_Hash_Is_Fnv1a_64;

   procedure A_Path_That_Fits_Stays_In_The_Record_Folder
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      --  With "/execution.sock", exactly Max_Length bytes.
      Longest : constant String :=
        "/" & [1 .. Max_Length - 1 - Socket_Name'Length - 1 => 'r'];
   begin
      Assert
        (Endpoint ("/w/pipelines/exec-1", 501)
         = "/w/pipelines/exec-1/execution.sock",
         "a short record folder");
      Assert
        (Endpoint (Longest, 501) = Longest & "/execution.sock",
         "and one whose socket path is exactly at the limit");
      Assert
        (not Is_Short (Endpoint (Longest, 501), 501), "is not the short form");
   end A_Path_That_Fits_Stays_In_The_Record_Folder;

   procedure A_Path_Too_Long_Goes_To_The_Short_Folder
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Folder : constant String :=
        "/" & [1 .. Max_Length - Socket_Name'Length - 1 => 'r'];
      Got    : constant String := Endpoint (Folder, 501);
   begin
      Assert
        (Got = "/tmp/synapse-pipeline-501/" & Fnv1a_64_Hex (Folder) & ".sock",
         "one byte over goes to the user's short folder: " & Got);
      Assert (Got'Length <= Max_Length, "and fits");
      Assert (Is_Short (Got, 501), "is the short form");
      Assert (not Is_Short (Got, 502), "of this user only");
      Assert
        (Short_Folder (4_294_967_294) = "/tmp/synapse-pipeline-4294967294",
         "a user id past Integer'Last");
   end A_Path_Too_Long_Goes_To_The_Short_Folder;

   --  realpath(3) spells each name as it is on disk. On a file system that
   --  ignores case, a folder asked for in the wrong case is found and given
   --  in its own case; where case matters it is not found and comes back as
   --  it was asked for.
   procedure The_Real_Path_Has_The_Case_On_Disk (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      Base    : constant String :=
        Socket_Folders.Real_Path (Synapse.Test_Scratch.Path (Scratch));
   begin
      if On_Windows then
         Synapse.Test_Scratch.Remove (Scratch);
         return;
      end if;
      Ada.Directories.Create_Path (Base & "/CaseDir/Inner");
      declare
         Asked : constant String := Base & "/casedir/inner";
         Got   : constant String := Socket_Folders.Real_Path (Asked);
      begin
         if Ada.Directories.Exists (Asked) then
            Assert
              (Got = Base & "/CaseDir/Inner",
               "the case on disk, not as asked: " & Got);
         else
            Assert (Got = Asked, "a path not found comes back as asked");
         end if;
      end;
      Synapse.Test_Scratch.Remove (Scratch);
   end The_Real_Path_Has_The_Case_On_Disk;

   procedure The_Real_Path_Resolves_Links (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      Base    : constant String :=
        Socket_Folders.Real_Path (Synapse.Test_Scratch.Path (Scratch));
      Args    : GNAT.OS_Lib.Argument_List (1 .. 3) :=
        [new String'("-s"), new String'(Base & "/Target"),
         new String'(Base & "/link")];
      Done    : Boolean;
   begin
      if On_Windows then
         Synapse.Test_Scratch.Remove (Scratch);
         return;
      end if;
      Ada.Directories.Create_Path (Base & "/Target");
      GNAT.OS_Lib.Spawn ("/bin/ln", Args, Done);
      for A of Args loop
         GNAT.OS_Lib.Free (A);
      end loop;
      Assert (Done, "the link was made");
      Assert
        (Socket_Folders.Real_Path (Base & "/link") = Base & "/Target",
         "a link resolves to its target");
      Assert
        (Socket_Folders.Real_Path (Base & "/missing") = Base & "/missing",
         "a path that does not exist comes back as it is");
      Synapse.Test_Scratch.Remove (Scratch);
   end The_Real_Path_Resolves_Links;

   --  The permission bits of Path, as `ls -ld` prints them.
   function Mode_Of (Path, Listing : String) return String is
      Args : GNAT.OS_Lib.Argument_List (1 .. 2) :=
        [new String'("-ld"), new String'(Path)];
      Done : Boolean;
      Code : Integer;
      File : Ada.Text_IO.File_Type;
   begin
      GNAT.OS_Lib.Spawn ("/bin/ls", Args, Listing, Done, Code);
      GNAT.OS_Lib.Free (Args (1));
      GNAT.OS_Lib.Free (Args (2));
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Listing);
      declare
         Line : constant String := Ada.Text_IO.Get_Line (File);
      begin
         Ada.Text_IO.Close (File);
         return Line (Line'First .. Line'First + 9);
      end;
   end Mode_Of;

   procedure A_Private_Folder_Is_Made_And_Checked
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      Base    : constant String := Synapse.Test_Scratch.Path (Scratch);
      Listing : constant String := Base & "/listing.txt";
      Args    : GNAT.OS_Lib.Argument_List (1 .. 3) :=
        [new String'("-s"), new String'(Base & "/made"),
         new String'(Base & "/link")];
      Done    : Boolean;
      File    : Ada.Text_IO.File_Type;
   begin
      if On_Windows then
         Synapse.Test_Scratch.Remove (Scratch);
         for A of Args loop
            GNAT.OS_Lib.Free (A);
         end loop;
         return;
      end if;

      Assert
        (Socket_Folders.Make_Private (Base & "/made") = "",
         "a missing folder is made");
      Assert
        (Mode_Of (Base & "/made", Listing) = "drwx------",
         "and only the user may use it");
      Assert
        (Socket_Folders.Make_Private (Base & "/made") = "",
         "and it can be used again");

      Ada.Directories.Create_Path (Base & "/open");
      GNAT.OS_Lib.Set_Executable (Base & "/open", GNAT.OS_Lib.S_Others);
      Assert
        (Socket_Folders.Make_Private (Base & "/open") = "",
         "a folder of the user's that others may enter");
      Assert
        (Mode_Of (Base & "/open", Listing) = "drwx------",
         "is made private");

      GNAT.OS_Lib.Spawn ("/bin/ln", Args, Done);
      Assert (Done, "the link was made");
      Assert
        (Socket_Folders.Make_Private (Base & "/link") /= "",
         "a symbolic link, even to the user's own folder, is refused");

      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Base & "/plain");
      Ada.Text_IO.Close (File);
      Assert
        (Socket_Folders.Make_Private (Base & "/plain") /= "",
         "and so is a file");

      for A of Args loop
         GNAT.OS_Lib.Free (A);
      end loop;
      Synapse.Test_Scratch.Remove (Scratch);
   end A_Private_Folder_Is_Made_And_Checked;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Socket_Paths");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Hash_Is_Fnv1a_64'Access, "The hash is FNV-1a 64");
      Register_Routine
        (T, A_Path_That_Fits_Stays_In_The_Record_Folder'Access,
         "A path that fits stays in the record folder");
      Register_Routine
        (T, A_Path_Too_Long_Goes_To_The_Short_Folder'Access,
         "A path too long goes to the short folder");
      Register_Routine
        (T, The_Real_Path_Has_The_Case_On_Disk'Access,
         "The real path has the case on disk");
      Register_Routine
        (T, The_Real_Path_Resolves_Links'Access,
         "The real path resolves links");
      Register_Routine
        (T, A_Private_Folder_Is_Made_And_Checked'Access,
         "A private folder is made and checked");
   end Register_Tests;

end Synapse.Pipeline.Socket_Paths.Tests;
