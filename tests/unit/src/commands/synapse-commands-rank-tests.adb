with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Tags_Cache;
with Synapse.Core.Graph_Model;
with Synapse.Core.Tag_Payload;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Rank.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Registry : constant String :=
     "{""ext"": {""repo"": ""u"", ""scope"": ""s""}}";

   function Definitions
     (Count : Natural) return Core.Tag_Payload.Tag_Vectors.Vector
   is
      Result : Core.Tag_Payload.Tag_Vectors.Vector;
   begin
      for I in 1 .. Count loop
         Result.Append
           (Core.Graph_Model.Tag'
              (Name       => To_Unbounded_String ("n"),
               Kind       => To_Unbounded_String ("function"),
               Which      => Core.Graph_Model.Def, Line => I,
               Expression => To_Unbounded_String ("e")));
      end loop;
      Result.Append
        (Core.Graph_Model.Tag'
           (Name       => To_Unbounded_String ("r"),
            Kind       => To_Unbounded_String ("call"),
            Which      => Core.Graph_Model.Ref, Line => 9,
            Expression => To_Unbounded_String ("e")));
      return Result;
   end Definitions;

   --  A repository of code files of known sizes, and a cache that says how
   --  many definitions each holds.
   procedure Setup (F : aliased in out Fixture; Dir : Scratch) is
      Cache   : Synapse.Adapters.Tags_Cache.Cache;
      Updates : Synapse.Adapters.Tags_Cache.Update_Vectors.Vector;
      Hash    : constant Core.Graph_Model.Hash := [others => 1];

      procedure Add
        (Name : String; Count : Natural; Unsupported : Boolean := False)
      is
      begin
         Updates.Append
           (Synapse.Adapters.Tags_Cache.Update'
              (Path  => To_Unbounded_String (Name),
               Which =>
                 (Hash        => Hash,
                  Tags        =>
                    To_Unbounded_String
                      (Core.Tag_Payload.Encode (Definitions (Count))),
                  Unsupported => Unsupported)));
      end Add;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      Put_Config (Dir, "synapse-grammars.conf", Registry);
      Put_File (Dir, "src/big.ext", [1 .. 1_000 => 'x']);
      Put_File (Dir, "src/dense.ext", [1 .. 100 => 'x']);
      Put_File (Dir, "src/plain.ext", [1 .. 500 => 'x']);
      Put_File (Dir, "src/engine_test.ext", [1 .. 100 => 'x']);
      Put_File (Dir, "src/empty.ext", "");
      Put_File (Dir, "src/odd.ext", [1 .. 100 => 'x']);
      Put_File (Dir, "src/Widget.decl", "x");
      Put_File (Dir, "src/WidgetHandler.ext", [1 .. 100 => 'x']);
      Commit_All (Dir);
      Ada.Directories.Create_Path (Path (Dir, "work"));
      Add ("src/big.ext", 2);
      Add ("src/dense.ext", 3);
      Add ("src/engine_test.ext", 5);
      Add ("src/odd.ext", 7, True);
      Synapse.Adapters.Tags_Cache.Open
        (Cache, Path (Dir, "work/_tags_cache.bin"));
      declare
         Written : constant Natural :=
           Synapse.Adapters.Tags_Cache.Commit
             (Cache, Updates, Core.Text_Lists.Vectors.Empty_Vector);
         pragma Unreferenced (Written);
      begin
         null;
      end;
   end Setup;

   procedure Sources (Dir : Scratch; Text : String) is
   begin
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "sources.txt"), Text);
   end Sources;

   procedure Rank_Orders_Code_By_Definitions_Per_Kilobyte
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Sources
        (Dir,
         "src/big.ext" & LF & "src/dense.ext" & LF & "src/plain.ext" & LF &
         "src/odd.ext" & LF & "src/empty.ext" & LF & "src/gone.ext" & LF);
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir))) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (F.Console.Out_Text =
         "code" & HT & "30.000" & HT & "src/dense.ext" & LF & "code" & HT &
         "2.000" & HT & "src/big.ext" & LF & "code" & HT & "0.000" & HT &
         "src/odd.ext" & LF & "code" & HT & "0.000" & HT & "src/plain.ext" &
         LF,
         "denser first, ties by path, empty and missing left out: " &
         F.Console.Out_Text);
      Assert
        (F.Console.Err_Text =
         "synapse-rank: pool summary, 6 sources -> code 4, dsl-consumers 0, unranked 0, tests-excluded 0" &
         LF,
         "the report: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rank_Orders_Code_By_Definitions_Per_Kilobyte;

   procedure Rank_Crux_Drops_The_Tests (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Sources (Dir, "src/dense.ext" & LF & "src/engine_test.ext" & LF);
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir),
               "--pool", "crux")) =
         0,
         "success");
      Assert
        (F.Console.Out_Text =
         "code" & HT & "30.000" & HT & "src/dense.ext" & LF,
         "no test: " & F.Console.Out_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "pool crux, 2 sources -> code 1") >
         0
         and then
           Ada.Strings.Fixed.Index (F.Console.Err_Text, "tests-excluded 1") >
           0,
         "reported");
      F.Console.Clear;
      F.Vars.Set ("SYNAPSE_TEST_PATH_RE", "dense");
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir),
               "--pool", "crux")) =
         0,
         "own pattern");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "engine_test") > 0
         and then Ada.Strings.Fixed.Index (F.Console.Out_Text, "dense") = 0,
         "the pattern decides: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rank_Crux_Drops_The_Tests;

   procedure Rank_Prints_Declarative_Files_By_Their_Consumers
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Sources (Dir, "src/Widget.decl" & LF);
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir))) =
         0,
         "success");
      Assert
        (F.Console.Out_Text =
         "dsl" & HT & "1" & HT & "src/WidgetHandler.ext" & LF,
         "the consumer: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir),
               "--tier", "code")) =
         0,
         "code only");
      Assert (F.Console.Out_Text = "", "no code in it");
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir),
               "--tier", "dsl")) =
         0,
         "dsl only");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "dsl" & HT) = 1,
         "that tier");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rank_Prints_Declarative_Files_By_Their_Consumers;

   procedure Rank_Top_Cuts_Each_Tier_And_Zero_Keeps_All
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Sources
        (Dir,
         "src/big.ext" & LF & "src/dense.ext" & LF & "src/plain.ext" & LF);
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir),
               "--top", "1")) =
         0,
         "one");
      Assert
        (F.Console.Out_Text =
         "code" & HT & "30.000" & HT & "src/dense.ext" & LF,
         "the best");
      F.Console.Clear;
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir),
               "--top", "0")) =
         0,
         "all");
      Assert
        (Ada.Strings.Fixed.Count (F.Console.Out_Text, "" & LF) = 3,
         "three rows");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rank_Top_Cuts_Each_Tier_And_Zero_Keeps_All;

   procedure Rank_Lists_Writes_Both_Pools_Of_Every_Node
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/001.txt"),
         "src/dense.ext" & LF & "src/engine_test.ext" & LF);
      Ada.Directories.Create_Path (Path (Dir, "lists"));
      Ada.Directories.Copy_File
        (Path (Dir, "work/001.txt"), Path (Dir, "lists/001.txt"));
      Assert
        (Run
           (Env (F),
            Args ("--lists", Path (Dir, "lists"), "--repo", Repo (Dir))) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Synapse.Adapters.File_Bytes.Read
           (Path (Dir, "work/rank/001.summary.tsv"), 1_000) =
         "code" & HT & "50.000" & HT & "src/engine_test.ext" & LF & "code" &
         HT & "30.000" & HT & "src/dense.ext" & LF,
         "the summary pool");
      Assert
        (Synapse.Adapters.File_Bytes.Read
           (Path (Dir, "work/rank/001.crux.tsv"), 1_000) =
         "code" & HT & "30.000" & HT & "src/dense.ext" & LF,
         "the crux pool has no test");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "synapse-rank: node 001, 2 sources -> code 2, dsl-consumers 0, unranked 0, tests-excluded 1") =
         1
         and then
           Ada.Strings.Fixed.Index
             (F.Console.Err_Text,
              "1 nodes ranked -> " & Path (Dir, "work/rank")) >
           0,
         "the report: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rank_Lists_Writes_Both_Pools_Of_Every_Node;

   procedure Rank_Says_When_It_Has_Nothing_To_Go_On
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Ada.Directories.Create_Path (Path (Dir, "lists"));
      Assert
        (Run
           (Env (F),
            Args ("--lists", Path (Dir, "lists"), "--repo", Repo (Dir))) =
         1,
         "no lists");
      Assert
        (Run
           (Env (F),
            Args ("--lists", Path (Dir, "gone"), "--repo", Repo (Dir))) =
         1,
         "no directory");
      Assert
        (Run
           (Env (F),
            Args ("--sources", Path (Dir, "gone.txt"), "--repo", Repo (Dir))) =
         1,
         "no sources");
      Assert
        (F.Console.Err_Text =
         "synapse-rank: no node lists (NN.txt) found in " &
         Path (Dir, "lists") & LF & "synapse-rank: no such lists dir: " &
         Path (Dir, "gone") & LF & "synapse-rank: no such sources file: " &
         Path (Dir, "gone.txt") & LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rank_Says_When_It_Has_Nothing_To_Go_On;

   procedure Rank_Warns_Of_An_Empty_Cache_And_Scores_Zero
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Ada.Directories.Delete_File (Path (Dir, "work/_tags_cache.bin"));
      Sources (Dir, "src/big.ext" & LF);
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir))) =
         0,
         "success");
      Assert
        (F.Console.Out_Text = "code" & HT & "0.000" & HT & "src/big.ext" & LF,
         "zero");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "synapse-rank: tags cache is empty (" &
            Path (Dir, "work/_tags_cache.bin") &
            ") -- every code-tier score will be zero; run synapse vocab first") =
         1,
         "the warning: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rank_Warns_Of_An_Empty_Cache_And_Scores_Zero;

   procedure Rank_Needs_A_Repository_And_A_Registry
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Sources (Dir, "src/big.ext" & LF);
      Put_Config (Dir, "synapse-grammars.conf", "not json");
      Assert
        (Run
           (Env (F),
            Args
              ("--sources", Path (Dir, "sources.txt"), "--repo", Repo (Dir))) =
         1,
         "bad registry");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "synapse-rank: cannot read the grammar registry") >
         0,
         "says so");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rank_Needs_A_Repository_And_A_Registry;

   procedure Rank_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "nothing to rank");
      Assert
        (Run (Env (F), Args ("--sources", "a", "--lists", "b")) = 2,
         "both inputs");
      Assert
        (Run (Env (F), Args ("--lists", "b", "--pool", "crux")) = 2,
         "a pool with lists");
      Assert
        (Run (Env (F), Args ("--lists", "b", "--tier", "code")) = 2,
         "a tier with lists");
      Assert
        (Run (Env (F), Args ("--sources", "a", "--tier", "nope")) = 2,
         "an unknown tier");
      Assert
        (Run (Env (F), Args ("--sources", "a", "--top", "many")) = 2,
         "top is a number");
      Assert (Run (Env (F), Args ("--sources")) = 2, "dangling");
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("-h")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse rank --sources") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rank_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Rank");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Rank_Orders_Code_By_Definitions_Per_Kilobyte'Access,
         "Rank orders code by definitions per kilobyte");
      Register_Routine
        (T, Rank_Crux_Drops_The_Tests'Access, "Rank crux drops the tests");
      Register_Routine
        (T, Rank_Prints_Declarative_Files_By_Their_Consumers'Access,
         "Rank prints declarative files by their consumers");
      Register_Routine
        (T, Rank_Top_Cuts_Each_Tier_And_Zero_Keeps_All'Access,
         "Rank top cuts each tier and zero keeps all");
      Register_Routine
        (T, Rank_Lists_Writes_Both_Pools_Of_Every_Node'Access,
         "Rank lists writes both pools of every node");
      Register_Routine
        (T, Rank_Says_When_It_Has_Nothing_To_Go_On'Access,
         "Rank says when it has nothing to go on");
      Register_Routine
        (T, Rank_Warns_Of_An_Empty_Cache_And_Scores_Zero'Access,
         "Rank warns of an empty cache and scores zero");
      Register_Routine
        (T, Rank_Needs_A_Repository_And_A_Registry'Access,
         "Rank needs a repository and a registry");
      Register_Routine (T, Rank_Arguments'Access, "Rank arguments");
   end Register_Tests;

end Synapse.Commands.Rank.Tests;
