with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with System.Multiprocessors;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.Graph_Model;
with Synapse.Core.Tag_Payload;
with Synapse.Ports.Extractor;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Vocab.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   package Port renames Synapse.Ports.Extractor;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Registry : constant String :=
     "{""ext"": {""repo"": ""u"", ""scope"": ""s""}}";

   function Named (Names : String) return Port.Outcome is
      Tags  : Core.Tag_Payload.Tag_Vectors.Vector;
      Start : Positive := Names'First;
   begin
      for I in Names'First .. Names'Last + 1 loop
         if I > Names'Last or else Names (I) = ' ' then
            Tags.Append
              (Core.Graph_Model.Tag'
                 (Name       => To_Unbounded_String (Names (Start .. I - 1)),
                  Kind       => To_Unbounded_String ("function"),
                  Which      => Core.Graph_Model.Def, Line => 1,
                  Expression => To_Unbounded_String ("e")));
            Start := I + 1;
         end if;
      end loop;
      return (Kind => Port.With_Tags, Tags => Tags);
   end Named;

   function Out_File (Dir : Scratch; Name : String) return String is
     (Synapse.Adapters.File_Bytes.Read (Path (Dir, "out/" & Name), 100_000));

   --  Two modules of code with their own symbols, one shared, and a file no
   --  grammar reads.
   procedure Setup (F : aliased in out Fixture; Dir : Scratch) is
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "out"));
      Put_Config (Dir, "synapse-grammars.conf", Registry);
      Put_File (Dir, "alpha/src/a.ext", "a");
      Put_File (Dir, "alpha/src/b.ext", "b");
      Put_File (Dir, "beta/src/c.ext", "c");
      Put_File (Dir, "beta/readme.md", "# beta");
      Put_File (Dir, "beta/dist/app.min.ext", "m");
      Commit_All (Dir);
      F.Extractors.Source.Script
        ("alpha/src/a.ext", Named ("startEngine stopEngine shared_helper"));
      F.Extractors.Source.Script ("alpha/src/b.ext", Named ("startEngine"));
      F.Extractors.Source.Script
        ("beta/src/c.ext", Named ("paintCanvas shared_helper"));
   end Setup;

   procedure Vocab_Writes_The_Six_Tables_And_Reports_Their_Size
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--depth", "1")) = 0,
         "success: " & F.Console.Err_Text);
      Assert
        (Out_File (Dir, "counts.tsv") =
         "beta" & HT & "3" & LF & "alpha" & HT & "2" & LF,
         "counts: " & Out_File (Dir, "counts.tsv"));
      Assert
        (Out_File (Dir, "groupexts.tsv") =
         "alpha" & HT & "ext" & HT & "2" & LF & "beta" & HT & "ext" & HT &
         "2" & LF & "beta" & HT & "md" & HT & "1" & LF,
         "kinds of file by group: " & Out_File (Dir, "groupexts.tsv"));
      Assert
        (Out_File (Dir, "parseable.tsv") =
         "alpha" & HT & "2" & HT & "2" & LF & "beta" & HT & "2" & HT & "3" &
         LF,
         "parseable share");
      Assert (Out_File (Dir, "namespaces.tsv") = "", "no rules, no table");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "synapse-vocab: groups 2, files 5, code 4, pairs ") =
         1,
         "the report: " & F.Console.Err_Text);
      Assert
        (Ada.Directories.Exists (Path (Dir, "out/distinctive.tsv")),
         "distinctive");
      Assert
        (Ada.Directories.Exists (Path (Dir, "out/_tags_cache.bin")),
         "the cache");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_Writes_The_Six_Tables_And_Reports_Their_Size;

   procedure Vocab_Counts_Words_Of_Symbols_By_Group
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--depth", "1")) = 0,
         "success");
      Assert
        (Out_File (Dir, "groupwords.tsv") =
         "alpha" & HT & "engine" & HT & "3" & LF & "alpha" & HT & "start" &
         HT & "2" & LF & "alpha" & HT & "helper" & HT & "1" & LF & "alpha" &
         HT & "shared" & HT & "1" & LF & "alpha" & HT & "stop" & HT & "1" &
         LF & "beta" & HT & "canvas" & HT & "1" & LF & "beta" & HT & "helper" &
         HT & "1" & LF & "beta" & HT & "paint" & HT & "1" & LF & "beta" & HT &
         "shared" & HT & "1" & LF,
         "words, by group then count then word: " &
         Out_File (Dir, "groupwords.tsv"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_Counts_Words_Of_Symbols_By_Group;

   procedure Vocab_Tags_Only_What_The_Cache_Lacks (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--depth", "1")) = 0,
         "first");
      Assert
        (F.Extractors.Source.Calls = 1
         and then Natural (F.Extractors.Source.Seen.Length) = 4,
         "the three code files: " &
         Natural'Image (Natural (F.Extractors.Source.Seen.Length)) &
         Natural'Image (F.Extractors.Source.Calls));
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--depth", "1")) = 0,
         "second");
      Assert (F.Extractors.Source.Calls = 1, "nothing to do the second time");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_Tags_Only_What_The_Cache_Lacks;

   procedure Vocab_With_Lists_Groups_By_Node (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Ada.Directories.Create_Path (Path (Dir, "lists"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "lists/001.title"), "Engine" & LF);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "lists/001.txt"),
         "alpha/src/a.ext" & LF & "alpha/src/b.ext" & LF);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "lists/002.title"), "Render" & LF);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "lists/002.txt"),
         "beta/src/c.ext" & LF & "alpha/src/a.ext" & LF);
      Assert
        (Run
           (Env (F),
            Args ("--repo", Repo (Dir), "--lists", Path (Dir, "lists"))) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Out_File (Dir, "counts.tsv") =
         "Engine" & HT & "2" & LF & "Render" & HT & "2" & LF,
         "a path two nodes list counts under both");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Err_Text, "files 3, code 3") > 0,
         "narrowed to what is listed: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_With_Lists_Groups_By_Node;

   procedure Vocab_With_No_Code_Says_So_And_Writes_An_Empty_Table
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "out"));
      Put_Config (Dir, "synapse-grammars.conf", "{}");
      Put_File (Dir, "a/x.md", "x");
      Commit_All (Dir);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--depth", "1")) = 0,
         "success");
      Assert (Out_File (Dir, "groupwords.tsv") = "", "empty");
      Assert
        (F.Console.Err_Text =
         "synapse-vocab: no files with a supported grammar -- use synapse-orientation instead" &
         LF,
         "the message: " & F.Console.Err_Text);
      Assert
        (not Ada.Directories.Exists (Path (Dir, "out/distinctive.tsv")),
         "no distinctive table");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_With_No_Code_Says_So_And_Writes_An_Empty_Table;

   procedure Vocab_Depth_Sets_How_Deep_The_Group_Goes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--depth", "1")) = 0,
         "one");
      Assert
        (Out_File (Dir, "counts.tsv") =
         "beta" & HT & "3" & LF & "alpha" & HT & "2" & LF,
         "directories: " & Out_File (Dir, "counts.tsv"));
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--depth", "2")) = 0,
         "two");
      Assert
        (Ada.Strings.Fixed.Index
           (Out_File (Dir, "counts.tsv"), "alpha/src" & HT & "2") >
         0,
         "deeper: " & Out_File (Dir, "counts.tsv"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_Depth_Sets_How_Deep_The_Group_Goes;

   procedure Vocab_Declared_Namespaces_Agree_Or_Do_Not
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_Config
        (Dir, "synapse-namespace-rules.conf",
         "{""ext"": {""kind"": ""in-file"", ""prefix"": ""package "", ""terminator"": "";""}}");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "repo/alpha/src/a.ext"), "package demo.one;" & LF);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "repo/alpha/src/b.ext"), "package demo.one;" & LF);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "repo/beta/src/c.ext"), "package demo.two;" & LF);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--depth", "1")) = 0,
         "success: " & F.Console.Err_Text);
      Assert
        (Out_File (Dir, "namespaces.tsv") =
         "alpha" & HT & "demo.one" & HT & "2" & HT & "2" & LF & "beta" & HT &
         "demo.two" & HT & "1" & HT & "1" & LF,
         "per group: " & Out_File (Dir, "namespaces.tsv"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_Declared_Namespaces_Agree_Or_Do_Not;

   procedure Vocab_Says_Why_It_Cannot (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_WORK_DIR", "");
      Assert
        (Run
           (Env (F),
            Args
              ("--repo", Path (Dir, "home"), "--out", Path (Dir, "o"),
               "--lists", Path (Dir, "nolists"))) =
         1,
         "no lists");
      Put_Config (Dir, "synapse-grammars.conf", "not json");
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--out", Path (Dir, "o"))) =
         1,
         "bad registry");
      Put_Config (Dir, "synapse-grammars.conf", Registry);
      Put_Config (Dir, "synapse-kind-synonyms.conf", "not json");
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--out", Path (Dir, "o"))) =
         1,
         "bad rules");
      Put_Config (Dir, "synapse-kind-synonyms.conf", "[]");
      Put_Config (Dir, "synapse-namespace-rules.conf", "not json");
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir), "--out", Path (Dir, "o"))) =
         1,
         "bad namespace rules");
      Assert
        (F.Console.Err_Text =
         "synapse-vocab: no such lists dir: " & Path (Dir, "nolists") & LF &
         "synapse-vocab: cannot read the grammar registry" & LF &
         "synapse-vocab: cannot read the kind-synonyms registry" & LF &
         "synapse-vocab: cannot read the namespace-rules registry" & LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_Says_Why_It_Cannot;

   procedure Vocab_Needs_An_Output_And_A_Repository
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_NAMESPACE", "w@m");
      F.Vars.Set ("HOME", "");
      Assert
        (Run (Env (F), Args) = 1 or else Run (Env (F), Args) = 1,
         "nowhere to write");
      Assert
        (Run
           (Env (F),
            Args ("--out", Path (Dir, "o"), "--repo", Path (Dir, "home"))) =
         1,
         "not a repository");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_Needs_An_Output_And_A_Repository;

   procedure Vocab_Tags_In_Slices_And_Puts_Them_Back_In_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run
           (Env (F),
            Args ("--repo", Repo (Dir), "--depth", "1", "--chunk", "1")) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (F.Extractors.Source.Calls =
         Natural'Min (Natural (System.Multiprocessors.Number_Of_CPUs), 4),
         "one call for each task: " &
         Natural'Image (F.Extractors.Source.Calls));
      Assert
        (Natural (F.Extractors.Source.Seen.Length) = 4,
         "every file asked once");
      declare
         Parallel : constant String := Out_File (Dir, "groupwords.tsv");
         Cache    : constant String :=
           Synapse.Adapters.File_Bytes.Read
             (Path (Dir, "out/_tags_cache.bin"), 1_000_000);
      begin
         Ada.Directories.Delete_File (Path (Dir, "out/_tags_cache.bin"));
         Assert
           (Run
              (Env (F),
               Args
                 ("--repo", Repo (Dir), "--depth", "1", "--chunk", "100000")) =
            0,
            "in turn");
         Assert
           (Out_File (Dir, "groupwords.tsv") = Parallel, "the same words");
         Assert
           (Synapse.Adapters.File_Bytes.Read
              (Path (Dir, "out/_tags_cache.bin"), 1_000_000) =
            Cache,
            "the same cache");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_Tags_In_Slices_And_Puts_Them_Back_In_Order;

   procedure An_Unsupported_File_Is_Recorded_And_Is_Not_A_Failure
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Extractors.Source.Script
        ("alpha/src/b.ext", (Kind => Port.Unsupported));
      Assert
        (Run
           (Env (F),
            Args ("--repo", Repo (Dir), "--depth", "1", "--chunk", "1")) =
         0,
         "an unsupported file is not a failure");
      Assert
        (Ada.Strings.Fixed.Index
           (Out_File (Dir, "groupwords.tsv"),
            "alpha" & HT & "engine" & HT & "2") >
         0,
         "the rest is tagged: " & Out_File (Dir, "groupwords.tsv"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Unsupported_File_Is_Recorded_And_Is_Not_A_Failure;

   procedure A_Failing_Task_Fails_The_Tagging (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Extractors.Source.Script_Failure ("alpha/src/b.ext");
      Assert
        (Run
           (Env (F),
            Args ("--repo", Repo (Dir), "--depth", "1", "--chunk", "1")) =
         1,
         "fails");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "synapse-vocab: a tagging worker failed") =
         1,
         "says so: " & F.Console.Err_Text);
      Assert
        (not Ada.Directories.Exists (Path (Dir, "out/groupwords.tsv")),
         "nothing after it");
      Assert
        (Run
           (Env (F),
            Args ("--repo", Repo (Dir), "--depth", "1", "--chunk", "100000")) =
         1,
         "in turn too");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Failing_Task_Fails_The_Tagging;

   procedure Vocab_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--depth", "0")) = 2, "depth is positive");
      Assert (Run (Env (F), Args ("--depth", "x")) = 2, "depth is a number");
      Assert
        (Run (Env (F), Args ("--distinctive-top", "0")) = 2,
         "top is positive");
      Assert
        (Run (Env (F), Args ("--distinctive-k", "0")) = 2, "k is positive");
      Assert
        (Run (Env (F), Args ("--chunk", "many")) = 2, "chunk is a number");
      Assert (Run (Env (F), Args ("--repo")) = 2, "dangling");
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse vocab [--repo <path>]") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocab_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Vocab");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Vocab_Writes_The_Six_Tables_And_Reports_Their_Size'Access,
         "Vocab writes the six tables and reports their size");
      Register_Routine
        (T, Vocab_Counts_Words_Of_Symbols_By_Group'Access,
         "Vocab counts words of symbols by group");
      Register_Routine
        (T, Vocab_Tags_Only_What_The_Cache_Lacks'Access,
         "Vocab tags only what the cache lacks");
      Register_Routine
        (T, Vocab_With_Lists_Groups_By_Node'Access,
         "Vocab with lists groups by node");
      Register_Routine
        (T, Vocab_With_No_Code_Says_So_And_Writes_An_Empty_Table'Access,
         "Vocab with no code says so and writes an empty table");
      Register_Routine
        (T, Vocab_Depth_Sets_How_Deep_The_Group_Goes'Access,
         "Vocab depth sets how deep the group goes");
      Register_Routine
        (T, Vocab_Declared_Namespaces_Agree_Or_Do_Not'Access,
         "Vocab declared namespaces agree or do not");
      Register_Routine
        (T, Vocab_Says_Why_It_Cannot'Access, "Vocab says why it cannot");
      Register_Routine
        (T, Vocab_Needs_An_Output_And_A_Repository'Access,
         "Vocab needs an output and a repository");
      Register_Routine
        (T, Vocab_Tags_In_Slices_And_Puts_Them_Back_In_Order'Access,
         "Vocab tags in slices and puts them back in order");
      Register_Routine
        (T, An_Unsupported_File_Is_Recorded_And_Is_Not_A_Failure'Access,
         "An unsupported file is recorded and is not a failure");
      Register_Routine
        (T, A_Failing_Task_Fails_The_Tagging'Access,
         "A failing task fails the tagging");
      Register_Routine (T, Vocab_Arguments'Access, "Vocab arguments");
   end Register_Tests;

end Synapse.Commands.Vocab.Tests;
