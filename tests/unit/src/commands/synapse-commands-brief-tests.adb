with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with AUnit.Assertions;

package body Synapse.Commands.Brief.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   procedure Put (Dir : Scratch; Name, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path (Dir, Name)));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, Name), Text);
   end Put;

   function Page (Dir : Scratch; Slug : String) return String is
     (Synapse.Adapters.File_Bytes.Read
        (Path (Dir, "out/brief/" & Slug & ".md"), 100_000));

   procedure Inputs (Dir : Scratch) is
   begin
      Put (Dir, "lists/001.title", "Alpha" & LF);
      Put (Dir, "lists/001.txt", "a.ext" & LF & LF & "b.ext" & LF);
      Put (Dir, "lists/002.title", "Beta" & LF);
      Put (Dir, "lists/002.txt", "c.ext" & LF);
      Put
        (Dir, "rank/001.summary.tsv",
         "code" & HT & "1.500" & HT & "a.ext" & LF);
      Put
        (Dir, "rank/001.crux.tsv",
         "code" & HT & "2.000" & HT & "b.ext" & LF & LF);
      Put
        (Dir, "links.tsv",
         "Beta" & HT & "Alpha" & HT & "2" & HT & "x y" & LF & "Alpha" & HT &
         "Beta" & HT & "1" & HT & "z" & LF & "Alpha" & HT & "Gamma" & HT &
         "1" & HT & "w" & LF);
      Put_File (Dir, "seed.txt", "x");
      Commit_All (Dir);
   end Inputs;

   procedure Brief_Args (F : aliased in out Fixture; Dir : Scratch) is
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
   end Brief_Args;

   procedure Brief_Writes_One_Page_For_Each_Node (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Brief_Args (F, Dir);
      Inputs (Dir);
      Assert
        (Run
           (Env (F),
            Args
              ("--lists", Path (Dir, "lists"), "--rank", Path (Dir, "rank"),
               "--links", Path (Dir, "links.tsv"), "--repo", Repo (Dir),
               "--out", Path (Dir, "out"))) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Page (Dir, "001") =
         "# Alpha" & LF & LF & "Repo root: " &
         Ada.Directories.Full_Name (Repo (Dir)) & LF & "Sources list: " &
         Path (Dir, "lists/001.txt") &
         " (2 files, exhaustive -- do not re-enumerate; `write-node` reads this list directly)" &
         LF & LF & "## Summary pool (ranked, read the top few)" & LF & "```" &
         LF & "code" & HT & "1.500" & HT & "a.ext" & LF & "```" & LF & LF &
         "## Crux pool (ranked, tests excluded)" & LF & "```" & LF & "code" &
         HT & "2.000" & HT & "b.ext" & LF & "```" & LF & LF &
         "## Candidate links (from the link graph; weight = distinct rare shared symbols)" &
         LF & "```" & LF & "Alpha" & HT & "Beta" & HT & "1" & HT & "z" & LF &
         "Alpha" & HT & "Gamma" & HT & "1" & HT & "w" & LF & "```" & LF & LF &
         "## Every node in this namespace (for judging part_of)" & LF &
         "- Alpha" & LF & "- Beta" & LF,
         "the whole page: " & Page (Dir, "001"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Brief_Writes_One_Page_For_Each_Node;

   procedure Brief_Leaves_An_Empty_Section_Where_There_Is_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Brief_Args (F, Dir);
      Inputs (Dir);
      Assert
        (Run
           (Env (F),
            Args
              ("--lists", Path (Dir, "lists"), "--rank", Path (Dir, "rank"),
               "--links", Path (Dir, "links.tsv"), "--repo", Repo (Dir),
               "--out", Path (Dir, "out"))) =
         0,
         "success");
      Assert
        (Ada.Strings.Fixed.Index
           (Page (Dir, "002"),
            "## Summary pool (ranked, read the top few)" & LF & "(none)" &
            LF) >
         0,
         "no pool: " & Page (Dir, "002"));
      Assert
        (Ada.Strings.Fixed.Index
           (Page (Dir, "002"),
            "```" & LF & "Beta" & HT & "Alpha" & HT & "2" & HT & "x y" & LF &
            "```") >
         0,
         "its own link row");
      Assert
        (Ada.Strings.Fixed.Index (Page (Dir, "002"), "Alpha" & HT & "Beta") =
         0,
         "and not another node's");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Brief_Leaves_An_Empty_Section_Where_There_Is_Nothing;

   procedure Brief_Warns_Of_What_Is_Missing_And_Goes_On
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Brief_Args (F, Dir);
      Inputs (Dir);
      Assert
        (Run
           (Env (F),
            Args
              ("--lists", Path (Dir, "lists"), "--rank", Path (Dir, "norank"),
               "--links", Path (Dir, "nolinks.tsv"), "--repo", Repo (Dir),
               "--out", Path (Dir, "out"))) =
         0,
         "success");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "synapse-brief: no link graph at " & Path (Dir, "nolinks.tsv")) =
         1,
         "the graph: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "2/2 nodes had no rank output at " & Path (Dir, "norank")) >
         0,
         "the pools");
      Assert
        (Ada.Directories.Exists (Path (Dir, "out/brief/002.md")),
         "written all the same");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Brief_Warns_Of_What_Is_Missing_And_Goes_On;

   procedure Brief_Defaults_To_The_Work_Directory (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Brief_Args (F, Dir);
      Inputs (Dir);
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      Ada.Directories.Create_Path (Path (Dir, "work"));
      Assert
        (Run
           (Env (F),
            Args ("--lists", Path (Dir, "lists"), "--repo", Repo (Dir))) =
         0,
         "success");
      Assert
        (Ada.Directories.Exists (Path (Dir, "work/brief/001.md")),
         "under the work directory");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Brief_Defaults_To_The_Work_Directory;

   procedure Brief_Needs_Lists_And_A_Repository (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      Away : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
   begin
      Brief_Args (F, Dir);
      Assert
        (Run (Env (F), Args ("--lists", Path (Dir, "none"))) = 1,
         "no lists dir");
      Ada.Directories.Create_Path (Path (Dir, "empty"));
      Ada.Directories.Create_Path (Path (Away, "empty"));
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      Assert
        (Run
           (Env (F),
            Args
              ("--lists", Path (Dir, "empty"), "--repo",
               Path (Away, "empty"))) =
         1,
         "not a repository");
      Inputs (Dir);
      Assert
        (Run
           (Env (F),
            Args ("--lists", Path (Dir, "empty"), "--repo", Repo (Dir))) =
         1,
         "no nodes");
      Assert
        (F.Console.Err_Text =
         "synapse-brief: no such lists dir: " & Path (Dir, "none") & LF &
         "synapse-brief: not inside a git repo: " & Path (Away, "empty") & LF &
         "synapse-brief: no NN.txt/NN.title pairs in " & Path (Dir, "empty") &
         LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Away);
   end Brief_Needs_Lists_And_A_Repository;

   procedure Brief_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "no lists");
      Assert (Run (Env (F), Args ("--lists")) = 2, "dangling");
      Assert
        (Run (Env (F), Args ("--lists", "--out")) = 2,
         "a flag is not a value");
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse brief --lists") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Brief_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Brief");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Brief_Writes_One_Page_For_Each_Node'Access,
         "Brief writes one page for each node");
      Register_Routine
        (T, Brief_Leaves_An_Empty_Section_Where_There_Is_Nothing'Access,
         "Brief leaves an empty section where there is nothing");
      Register_Routine
        (T, Brief_Warns_Of_What_Is_Missing_And_Goes_On'Access,
         "Brief warns of what is missing and goes on");
      Register_Routine
        (T, Brief_Defaults_To_The_Work_Directory'Access,
         "Brief defaults to the work directory");
      Register_Routine
        (T, Brief_Needs_Lists_And_A_Repository'Access,
         "Brief needs lists and a repository");
      Register_Routine (T, Brief_Arguments'Access, "Brief arguments");
   end Register_Tests;

end Synapse.Commands.Brief.Tests;
