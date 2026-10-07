with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.Graph_Model;
with Synapse.Core.Tag_Payload;
with Synapse.Ports.Extractor;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with Synapse.Commands.Tags_Cache;
with AUnit.Assertions;

package body Synapse.Commands.Refs.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   package Port renames Synapse.Ports.Extractor;
   package Graph renames Synapse.Core.Graph_Model;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Hash_A : constant String := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

   function Make_Tag
     (Name, Kind : String; Line : Natural; Which : Graph.Role)
      return Graph.Tag is
     (Name => To_Unbounded_String (Name), Kind => To_Unbounded_String (Kind),
      Which      => Which, Line => Line,
      Expression => To_Unbounded_String (Name & "()"));

   --  A work directory with a tags cache of two files and one that no grammar
   --  could read: a definition, two calls and a plain reference of `run`.
   procedure Cache (F : aliased in out Fixture; Dir : Scratch) is
      Tags : Synapse.Core.Tag_Payload.Tag_Vectors.Vector;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      Put_Config
        (Dir, "synapse-grammars.conf",
         "{""ext"": {""repo"": ""u"", ""scope"": ""s""}}");
      Ada.Directories.Create_Path (Path (Dir, "repo"));
      Ada.Directories.Create_Path (Path (Dir, "work"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "paths.tsv"),
         "a.ext" & HT & Hash_A & LF & "b.ext" & HT & Hash_A & LF & "c.none" &
         HT & Hash_A & LF);
      Tags.Append (Make_Tag ("run", "function", 1, Graph.Def));
      Tags.Append (Make_Tag ("run", "call", 5, Graph.Ref));
      F.Extractors.Source.Script
        ("a.ext", (Kind => Port.With_Tags, Tags => Tags));
      Tags.Clear;
      Tags.Append (Make_Tag ("run", "call", 2, Graph.Ref));
      Tags.Append (Make_Tag ("run", "implementation", 8, Graph.Ref));
      Tags.Append (Make_Tag ("stop", "function", 3, Graph.Def));
      F.Extractors.Source.Script
        ("b.ext", (Kind => Port.With_Tags, Tags => Tags));
      F.Extractors.Source.Script ("c.none", (Kind => Port.Unsupported));
   end Cache;

   procedure Build_Everything (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Cache (F, Dir);
      Assert
        (Synapse.Commands.Tags_Cache.Run
           (Env (F),
            Args
              ("--repo-root", Path (Dir, "repo"), "--cache",
               Path (Dir, "work/_tags_cache.bin"), "--paths",
               Path (Dir, "paths.tsv"))) =
         0,
         "the cache is built: " & F.Console.Err_Text);
      Assert
        (Run_Build (Env (F), Args) = 0,
         "the index is built: " & F.Console.Err_Text);
      F.Console.Clear;
   end Build_Everything;

   procedure Build_Refs_Writes_The_Sorted_Index_And_Reports_Its_Counts
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Build_Everything (F, Dir);
      Assert
        (Synapse.Adapters.File_Bytes.Read
           (Path (Dir, "work/_refs.tsv"), 100_000) =
         "run" & HT & "def" & HT & "function" & HT & "a.ext:1" & HT & "run()" &
         LF & "run" & HT & "ref" & HT & "call" & HT & "a.ext:5" & HT &
         "run()" & LF & "run" & HT & "ref" & HT & "call" & HT & "b.ext:2" &
         HT & "run()" & LF & "run" & HT & "ref" & HT & "implementation" & HT &
         "b.ext:8" & HT & "run()" & LF & "stop" & HT & "def" & HT &
         "function" & HT & "b.ext:3" & HT & "stop()" & LF,
         "sorted rows");
      Assert (Run_Build (Env (F), Args) = 0, "again");
      Assert
        (F.Console.Err_Text =
         "synapse-build-refs: 5 tags (2 def, 3 ref) over 2 files, 1 unsupported -> " &
         Path (Dir, "work/_refs.tsv") & LF,
         "the report: " & F.Console.Err_Text);
      Assert (F.Console.Out_Text = "", "on standard error only");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Refs_Writes_The_Sorted_Index_And_Reports_Its_Counts;

   procedure Build_Refs_Takes_The_Cache_And_The_Output_By_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Build_Everything (F, Dir);
      F.Vars.Set ("SYNAPSE_WORK_DIR", "");
      F.Vars.Set ("HOME", "");
      Assert
        (Run_Build
           (Env (F),
            Args
              ("--cache", Path (Dir, "work/_tags_cache.bin"), "--out",
               Path (Dir, "x.tsv"))) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Ada.Directories.Exists (Path (Dir, "x.tsv")), "written where asked");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Refs_Takes_The_Cache_And_The_Output_By_Name;

   procedure Build_Refs_Says_When_There_Is_No_Cache
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Cache (F, Dir);
      Assert (Run_Build (Env (F), Args) = 1, "none");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/_tags_cache.bin"), [1 .. 100 => 'x']);
      F.Console.Clear;
      Assert (Run_Build (Env (F), Args) = 1, "unreadable");
      Assert
        (F.Console.Err_Text =
         "synapse-build-refs: unreadable cache: " &
         Path (Dir, "work/_tags_cache.bin") & LF,
         "the message");
      F.Vars.Set ("HOME", "");
      F.Vars.Set ("SYNAPSE_WORK_DIR", "");
      F.Vars.Set ("SYNAPSE_NAMESPACE", "w@m");
      F.Console.Clear;
      Assert (Run_Build (Env (F), Args) = 1, "no work directory");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Refs_Says_When_There_Is_No_Cache;

   procedure Build_Refs_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run_Build (Env (F), Args ("--wat")) = 2, "unknown");
      Assert (Run_Build (Env (F), Args ("--cache")) = 2, "dangling");
      F.Console.Clear;
      Assert (Run_Build (Env (F), Args ("-h")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse build-refs [--cache <path>]") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Refs_Arguments;

   procedure Callers_Prints_The_Calls_Of_A_Name (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Build_Everything (F, Dir);
      Assert (Run_Callers (Env (F), Args ("run")) = 0, "success");
      Assert
        (F.Console.Out_Text =
         "a.ext:5" & HT & "run()" & LF & "b.ext:2" & HT & "run()" & LF,
         "only the calls: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Callers_Prints_The_Calls_Of_A_Name;

   procedure Callers_With_All_Prints_Every_Def_And_Ref
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Build_Everything (F, Dir);
      Assert (Run_Callers (Env (F), Args ("run", "--all")) = 0, "success");
      Assert
        (F.Console.Out_Text =
         "def" & HT & "function" & HT & "a.ext:1" & HT & "run()" & LF & "ref" &
         HT & "call" & HT & "a.ext:5" & HT & "run()" & LF & "ref" & HT &
         "call" & HT & "b.ext:2" & HT & "run()" & LF & "ref" & HT &
         "implementation" & HT & "b.ext:8" & HT & "run()" & LF,
         "every row: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Callers_With_All_Prints_Every_Def_And_Ref;

   procedure Callers_Matches_The_Whole_Name_And_Is_Quiet_About_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Build_Everything (F, Dir);
      Assert (Run_Callers (Env (F), Args ("ru")) = 0, "a prefix");
      Assert (Run_Callers (Env (F), Args ("runner")) = 0, "an extension");
      Assert (Run_Callers (Env (F), Args ("stop")) = 0, "a name with no call");
      Assert (F.Console.Out_Text = "", "nothing printed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Callers_Matches_The_Whole_Name_And_Is_Quiet_About_None;

   procedure Callers_Reads_Another_Index_By_File_Or_Namespace
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Build_Everything (F, Dir);
      F.Vars.Set ("SYNAPSE_WORK_DIR", "");
      Assert
        (Run_Callers
           (Env (F), Args ("run", "--refs", Path (Dir, "work/_refs.tsv"))) =
         0,
         "by file");
      F.Console.Clear;
      Ada.Directories.Create_Path (Path (Dir, "home/.cache/synapse/work/w@m"));
      Ada.Directories.Copy_File
        (Path (Dir, "work/_refs.tsv"),
         Path (Dir, "home/.cache/synapse/work/w@m/_refs.tsv"));
      Assert
        (Run_Callers (Env (F), Args ("run", "--namespace", "w@m")) = 0,
         "by namespace");
      Assert
        (F.Console.Out_Text =
         "a.ext:5" & HT & "run()" & LF & "b.ext:2" & HT & "run()" & LF,
         "the same rows: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Callers_Reads_Another_Index_By_File_Or_Namespace;

   procedure Callers_Says_When_There_Is_No_Index (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Cache (F, Dir);
      Assert (Run_Callers (Env (F), Args ("run")) = 1, "code 1");
      Assert
        (F.Console.Err_Text =
         "synapse-callers: no reference index at " &
         Path (Dir, "work/_refs.tsv") & " -- run `synapse build-refs`" & LF,
         "the message: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Callers_Says_When_There_Is_No_Index;

   procedure Callers_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run_Callers (Env (F), Args) = 2, "no name");
      Assert (Run_Callers (Env (F), Args ("a", "b")) = 2, "two names");
      Assert (Run_Callers (Env (F), Args ("-x")) = 2, "unknown flag");
      Assert (Run_Callers (Env (F), Args ("a", "--refs")) = 2, "dangling");
      Assert
        (Run_Callers
           (Env (F), Args ("a", "--refs", "r", "--namespace", "w@m")) =
         2,
         "both");
      F.Console.Clear;
      Assert (Run_Callers (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse callers <name> [--all]") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Callers_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Refs");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Build_Refs_Writes_The_Sorted_Index_And_Reports_Its_Counts'Access,
         "Build refs writes the sorted index and reports its counts");
      Register_Routine
        (T, Build_Refs_Takes_The_Cache_And_The_Output_By_Name'Access,
         "Build refs takes the cache and the output by name");
      Register_Routine
        (T, Build_Refs_Says_When_There_Is_No_Cache'Access,
         "Build refs says when there is no cache");
      Register_Routine
        (T, Build_Refs_Arguments'Access, "Build refs arguments");
      Register_Routine
        (T, Callers_Prints_The_Calls_Of_A_Name'Access,
         "Callers prints the calls of a name");
      Register_Routine
        (T, Callers_With_All_Prints_Every_Def_And_Ref'Access,
         "Callers with all prints every def and ref");
      Register_Routine
        (T, Callers_Matches_The_Whole_Name_And_Is_Quiet_About_None'Access,
         "Callers matches the whole name and is quiet about none");
      Register_Routine
        (T, Callers_Reads_Another_Index_By_File_Or_Namespace'Access,
         "Callers reads another index by file or namespace");
      Register_Routine
        (T, Callers_Says_When_There_Is_No_Index'Access,
         "Callers says when there is no index");
      Register_Routine (T, Callers_Arguments'Access, "Callers arguments");
   end Register_Tests;

end Synapse.Commands.Refs.Tests;
