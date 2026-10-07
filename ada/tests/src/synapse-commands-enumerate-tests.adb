with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Enumerate.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;

   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);

   procedure Mixed_Repo (Dir : Scratch) is
   begin
      Put_File (Dir, "mod-a/src/A.ext", "class A" & LF);
      Put_File (Dir, "docs/guide.md", "# guide" & LF);
      Put_File (Dir, "stray.txt", "stray" & LF);
      Put_File (Dir, "assets/logo.png", "PNG" & LF);
      Put_File (Dir, "yarn.lock", "lock" & LF);
      Put_File (Dir, "dist/app.min.js", "{}" & LF);
      Commit_All (Dir);
   end Mixed_Repo;

   procedure Enumerate_Lists_The_Tracked_Files_Worth_Graphing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Mixed_Repo (Dir);
      Assert (Enumerate (Env (F), Repo (Dir), False) = 0, "success");
      Assert
        (Work_File (Dir, "all.txt") =
         "docs/guide.md" & LF & "mod-a/src/A.ext" & LF & "stray.txt" & LF,
         "no binary, no lockfile, no bundle: " & Work_File (Dir, "all.txt"));
      Assert
        (F.Console.Out_Text =
         "--- enumerating tracked files" & LF & "enumerated: 3" & LF,
         "the banner and the count: " & F.Console.Out_Text);
      Assert (Work_File (Dir, "oversize.txt") = "", "nothing oversize");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Lists_The_Tracked_Files_Worth_Graphing;

   procedure Enumerate_Reuses_A_Non_Empty_List_Unless_Told_To_Rebuild
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Mixed_Repo (Dir);
      Ada.Directories.Create_Path (Path (Dir, "work"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/all.txt"), "old.txt" & LF);
      Assert (Enumerate (Env (F), Repo (Dir), False) = 0, "reuse");
      Assert
        (F.Console.Out_Text = "enumerated: 1" & LF,
         "no banner: " & F.Console.Out_Text);
      Assert (Work_File (Dir, "all.txt") = "old.txt" & LF, "untouched");
      F.Console.Clear;
      Assert (Enumerate (Env (F), Repo (Dir), True) = 0, "rebuild");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "--- enumerating") = 1,
         "banner");
      Assert
        (Ada.Strings.Fixed.Index (Work_File (Dir, "all.txt"), "old.txt") = 0,
         "rebuilt");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Reuses_A_Non_Empty_List_Unless_Told_To_Rebuild;

   procedure Enumerate_Rebuilds_An_Empty_List (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Mixed_Repo (Dir);
      Ada.Directories.Create_Path (Path (Dir, "work"));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work/all.txt"), "");
      Assert (Enumerate (Env (F), Repo (Dir), False) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Index (Work_File (Dir, "all.txt"), "stray.txt") > 0,
         "rebuilt");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Rebuilds_An_Empty_List;

   procedure Enumerate_Reports_The_Files_Over_The_Size_Cap_Largest_First
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      F.Vars.Set ("SYNAPSE_MAX_FILE_BYTES", "10");
      for I in 1 .. 7 loop
         Put_File
           (Dir, "big" & Character'Val (Character'Pos ('0') + I) & ".txt",
            [1 .. 10 + I => 'x']);
      end loop;
      Put_File (Dir, "small.txt", "ok");
      Put_File (Dir, "exact.txt", [1 .. 10 => 'x']);
      Commit_All (Dir);
      Assert (Enumerate (Env (F), Repo (Dir), False) = 0, "success");
      Assert
        (Work_File (Dir, "all.txt") = "exact.txt" & LF & "small.txt" & LF,
         "the small ones, one exactly at the cap");
      Assert
        (F.Console.Out_Text =
         "--- enumerating tracked files" & LF &
         "skipped 7 file(s) over 10 bytes (largest first):" & LF &
         "          17  big7.txt" & LF & "          16  big6.txt" & LF &
         "          15  big5.txt" & LF & "          14  big4.txt" & LF &
         "          13  big3.txt" & LF & "enumerated: 2" & LF,
         "five of them: " & F.Console.Out_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (Work_File (Dir, "oversize.txt"), "11" & ASCII.HT & "big1.txt") =
         1,
         "all seven recorded");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Reports_The_Files_Over_The_Size_Cap_Largest_First;

   procedure Enumerate_Applies_The_User_S_Exclusion_Patterns
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Mixed_Repo (Dir);
      F.Vars.Set ("SYNAPSE_EXTRA_EXCLUDE_RE", "^docs/");
      Put_Config
        (Dir, "synapse-ignore-files.conf",
         "# a comment" & LF & "stray\.txt   # trailing" & LF & LF);
      Assert (Enumerate (Env (F), Repo (Dir), False) = 0, "success");
      Assert
        (Work_File (Dir, "all.txt") = "mod-a/src/A.ext" & LF,
         "both patterns apply: " & Work_File (Dir, "all.txt"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Applies_The_User_S_Exclusion_Patterns;

   procedure Enumerate_Leaves_Out_A_Tracked_File_That_Is_Gone
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Mixed_Repo (Dir);
      Ada.Directories.Delete_File (Path (Dir, "repo/stray.txt"));
      Assert (Enumerate (Env (F), Repo (Dir), False) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Index (Work_File (Dir, "all.txt"), "stray") = 0,
         "gone");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Leaves_Out_A_Tracked_File_That_Is_Gone;

   procedure Enumerate_Says_When_A_Pattern_Is_Not_A_Regular_Expression
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Mixed_Repo (Dir);
      F.Vars.Set ("SYNAPSE_EXTRA_EXCLUDE_RE", "(");
      Assert (Enumerate (Env (F), Repo (Dir), False) = 1, "code 1");
      Assert
        (F.Console.Err_Text = "synapse-enumerate: grep failed" & LF,
         "the message: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Says_When_A_Pattern_Is_Not_A_Regular_Expression;

   procedure Enumerate_Outside_A_Repository_Fails (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make_Outside_Git;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Assert (Enumerate (Env (F), Path (Dir), False) = 1, "code 1");
      Assert
        (F.Console.Err_Text = "synapse-enumerate: not inside a git repo" & LF,
         "the message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Outside_A_Repository_Fails;

   procedure Enumerate_Without_A_Home_Has_No_Work_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Mixed_Repo (Dir);
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      Assert (Enumerate (Env (F), Repo (Dir), False) = 1, "code 1");
      Assert
        (F.Console.Err_Text =
         "synapse-enumerate: no HOME, so no default work dir" & LF,
         "the message: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Without_A_Home_Has_No_Work_Directory;

   procedure Enumerate_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      Assert
        (F.Console.Err_Text = "usage: synapse enumerate [--reenumerate]" & LF,
         "usage");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("-h")) = 0, "help");
      Assert
        (F.Console.Err_Text = "usage: synapse enumerate [--reenumerate]" & LF,
         "usage again");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enumerate_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Enumerate");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Enumerate_Lists_The_Tracked_Files_Worth_Graphing'Access,
         "Enumerate lists the tracked files worth graphing");
      Register_Routine
        (T, Enumerate_Reuses_A_Non_Empty_List_Unless_Told_To_Rebuild'Access,
         "Enumerate reuses a non empty list unless told to rebuild");
      Register_Routine
        (T, Enumerate_Rebuilds_An_Empty_List'Access,
         "Enumerate rebuilds an empty list");
      Register_Routine
        (T, Enumerate_Reports_The_Files_Over_The_Size_Cap_Largest_First'Access,
         "Enumerate reports the files over the size cap largest first");
      Register_Routine
        (T, Enumerate_Applies_The_User_S_Exclusion_Patterns'Access,
         "Enumerate applies the user's exclusion patterns");
      Register_Routine
        (T, Enumerate_Leaves_Out_A_Tracked_File_That_Is_Gone'Access,
         "Enumerate leaves out a tracked file that is gone");
      Register_Routine
        (T, Enumerate_Says_When_A_Pattern_Is_Not_A_Regular_Expression'Access,
         "Enumerate says when a pattern is not a regular expression");
      Register_Routine
        (T, Enumerate_Outside_A_Repository_Fails'Access,
         "Enumerate outside a repository fails");
      Register_Routine
        (T, Enumerate_Without_A_Home_Has_No_Work_Directory'Access,
         "Enumerate without a home has no work directory");
      Register_Routine (T, Enumerate_Arguments'Access, "Enumerate arguments");
   end Register_Tests;

end Synapse.Commands.Enumerate.Tests;
