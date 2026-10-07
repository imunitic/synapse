with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with AUnit.Assertions;

package body Synapse.Commands.Build_Lists.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   procedure Manifest (Dir : Scratch; Text : String) is
   begin
      Ada.Directories.Create_Path (Path (Dir, "work"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/manifest.tsv"), Text);
   end Manifest;

   procedure Sample_Repo (Dir : Scratch) is
   begin
      Put_File (Dir, "src/a/A.ext", "a" & LF);
      Put_File (Dir, "src/b/B.ext", "b" & LF);
      Put_File (Dir, "src/b/B.md", "b" & LF);
      Put_File (Dir, "docs/guide.md", "g" & LF);
      Put_File (Dir, "Zed.txt", "z" & LF);
      Put_File (Dir, "apple.txt", "a" & LF);
      Commit_All (Dir);
   end Sample_Repo;

   procedure Parse_Row_Reads_Title_Include_And_Exclude
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      declare
         Got : constant Maybe_Row :=
           Parse_Row ("Core" & HT & "^src/" & HT & "\.md$");
      begin
         Assert (Got.Found, "a row");
         Assert (To_String (Got.Title) = "Core", "title");
         Assert (To_String (Got.Include) = "^src/", "include");
         Assert (To_String (Got.Exclude) = "\.md$", "exclude");
      end;
   end Parse_Row_Reads_Title_Include_And_Exclude;

   procedure Parse_Row_Accepts_A_Missing_Exclude_And_Skips_A_Short_Row
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      declare
         Two : constant Maybe_Row := Parse_Row ("T" & HT & "inc");
         CR  : constant Maybe_Row :=
           Parse_Row ("T" & HT & "inc" & HT & "x" & ASCII.CR);
      begin
         Assert
           (Two.Found and then Length (Two.Exclude) = 0, "excludes nothing");
         Assert
           (CR.Found and then To_String (CR.Exclude) = "x",
            "a carriage return is not part of it");
      end;
      Assert (not Parse_Row ("").Found, "blank");
      Assert (not Parse_Row ("OnlyTitle").Found, "no include");
      Assert (not Parse_Row (HT & "inc").Found, "no title");
   end Parse_Row_Accepts_A_Missing_Exclude_And_Skips_A_Short_Row;

   procedure Build_Lists_Writes_A_List_Per_Node_And_The_Coverage
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample_Repo (Dir);
      Manifest
        (Dir,
         "Core" & HT & "^src/a/" & HT & LF & "Bee" & HT & "^src/b/" & HT &
         "\.md$" & LF & "Docs" & HT & "\.md$" & LF);
      Assert
        (Build (Env (F), Repo (Dir), False) = 0,
         "success: " & F.Console.Err_Text);
      Assert
        (Work_File (Dir, "lists/001.txt") = "src/a/A.ext" & LF, "first list");
      Assert (Work_File (Dir, "lists/001.title") = "Core" & LF, "its title");
      Assert
        (Work_File (Dir, "lists/002.txt") = "src/b/B.ext" & LF,
         "exclude applied");
      Assert
        (Work_File (Dir, "lists/003.txt") =
         "docs/guide.md" & LF & "src/b/B.md" & LF,
         "third");
      Assert
        (F.Console.Out_Text =
         "--- enumerating tracked files" & LF & "enumerated: 6" & LF & "001" &
         HT & "1" & HT & "Core" & LF & "002" & HT & "1" & HT & "Bee" & LF &
         "003" & HT & "2" & HT & "Docs" & LF & "--- coverage" & LF &
         "covered:    4" & LF & "unassigned: 2" & LF,
         "the report: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Lists_Writes_A_List_Per_Node_And_The_Coverage;

   procedure Build_Lists_Sorts_By_Bytes_So_Capitals_Come_First
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample_Repo (Dir);
      Manifest (Dir, "Core" & HT & "^src/a/" & HT & LF);
      Assert (Build (Env (F), Repo (Dir), False) = 0, "success");
      Assert
        (Work_File (Dir, "all-sorted.txt") =
         "Zed.txt" & LF & "apple.txt" & LF & "docs/guide.md" & LF &
         "src/a/A.ext" & LF & "src/b/B.ext" & LF & "src/b/B.md" & LF,
         "uppercase before lowercase");
      Assert (Work_File (Dir, "covered.txt") = "src/a/A.ext" & LF, "covered");
      Assert
        (Work_File (Dir, "unassigned.txt") =
         "Zed.txt" & LF & "apple.txt" & LF & "docs/guide.md" & LF &
         "src/b/B.ext" & LF & "src/b/B.md" & LF,
         "what no node claims");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Lists_Sorts_By_Bytes_So_Capitals_Come_First;

   procedure Build_Lists_Counts_A_Path_Two_Nodes_Claim_Once
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample_Repo (Dir);
      Manifest
        (Dir,
         "One" & HT & "^src/" & HT & LF & "Two" & HT & "^src/a" & HT & LF);
      Assert (Build (Env (F), Repo (Dir), False) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "covered:    3") > 0,
         "once: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Lists_Counts_A_Path_Two_Nodes_Claim_Once;

   procedure Build_Lists_Is_Rebuilt_From_Nothing (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample_Repo (Dir);
      Ada.Directories.Create_Path (Path (Dir, "work/lists"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/lists/009.txt"), "stale");
      Manifest (Dir, "Core" & HT & "^src/a/" & HT & LF);
      Assert (Build (Env (F), Repo (Dir), False) = 0, "success");
      Assert
        (not Ada.Directories.Exists (Path (Dir, "work/lists/009.txt")),
         "no stale list");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Lists_Is_Rebuilt_From_Nothing;

   procedure Build_Lists_Without_A_Manifest_Says_So_Before_Enumerating
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample_Repo (Dir);
      Assert (Build (Env (F), Repo (Dir), False) = 1, "code 1");
      Assert
        (F.Console.Err_Text =
         "synapse-build-lists: no manifest.tsv in " & Path (Dir, "work") & LF,
         "the message: " & F.Console.Err_Text);
      Assert (F.Console.Out_Text = "", "nothing enumerated");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Lists_Without_A_Manifest_Says_So_Before_Enumerating;

   procedure Build_Lists_Says_When_A_Pattern_Is_Not_A_Regular_Expression
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample_Repo (Dir);
      Manifest (Dir, "Bad" & HT & "(" & HT & LF);
      Assert (Build (Env (F), Repo (Dir), False) = 1, "code 1");
      Assert
        (F.Console.Err_Text = "synapse-build-lists: grep failed" & LF,
         "the message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Lists_Says_When_A_Pattern_Is_Not_A_Regular_Expression;

   procedure Build_Lists_Refuses_More_Nodes_Than_There_Are_Slugs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample_Repo (Dir);
      declare
         Rows : Unbounded_String;
      begin
         for I in 1 .. 201 loop
            Append (Rows, "N" & HT & "^src/" & HT & LF);
         end loop;
         Manifest (Dir, To_String (Rows));
      end;
      Assert (Build (Env (F), Repo (Dir), False) = 1, "code 1");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "manifest has more than 200 nodes") >
         0,
         "the message");
      Assert
        (Ada.Directories.Exists (Path (Dir, "work/lists/200.txt")),
         "200 were written");
      Assert
        (not Ada.Directories.Exists (Path (Dir, "work/lists/201.txt")),
         "not the 201st");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Lists_Refuses_More_Nodes_Than_There_Are_Slugs;

   procedure Build_Lists_Outside_A_Repository_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make_Outside_Git;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Assert (Build (Env (F), Path (Dir), False) = 1, "code 1");
      Assert
        (F.Console.Err_Text =
         "synapse-build-lists: not inside a git repo" & LF,
         "the message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Lists_Outside_A_Repository_Fails;

   procedure Build_Lists_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (F.Console.Err_Text =
         "usage: synapse build-lists [--reenumerate]" & LF,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Lists_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Build_Lists");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Parse_Row_Reads_Title_Include_And_Exclude'Access,
         "Parse row reads title include and exclude");
      Register_Routine
        (T, Parse_Row_Accepts_A_Missing_Exclude_And_Skips_A_Short_Row'Access,
         "Parse row accepts a missing exclude and skips a short row");
      Register_Routine
        (T, Build_Lists_Writes_A_List_Per_Node_And_The_Coverage'Access,
         "Build lists writes a list per node and the coverage");
      Register_Routine
        (T, Build_Lists_Sorts_By_Bytes_So_Capitals_Come_First'Access,
         "Build lists sorts by bytes so capitals come first");
      Register_Routine
        (T, Build_Lists_Counts_A_Path_Two_Nodes_Claim_Once'Access,
         "Build lists counts a path two nodes claim once");
      Register_Routine
        (T, Build_Lists_Is_Rebuilt_From_Nothing'Access,
         "Build lists is rebuilt from nothing");
      Register_Routine
        (T, Build_Lists_Without_A_Manifest_Says_So_Before_Enumerating'Access,
         "Build lists without a manifest says so before enumerating");
      Register_Routine
        (T, Build_Lists_Says_When_A_Pattern_Is_Not_A_Regular_Expression'Access,
         "Build lists says when a pattern is not a regular expression");
      Register_Routine
        (T, Build_Lists_Refuses_More_Nodes_Than_There_Are_Slugs'Access,
         "Build lists refuses more nodes than there are slugs");
      Register_Routine
        (T, Build_Lists_Outside_A_Repository_Fails'Access,
         "Build lists outside a repository fails");
      Register_Routine
        (T, Build_Lists_Arguments'Access, "Build lists arguments");
   end Register_Tests;

end Synapse.Commands.Build_Lists.Tests;
