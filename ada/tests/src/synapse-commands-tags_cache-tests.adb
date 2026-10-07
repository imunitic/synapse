with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Tags_Cache;
with Synapse.Core.Graph_Model;
with Synapse.Core.Tag_Payload;
with Synapse.Ports.Extractor;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Tags_Cache.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   package Port renames Synapse.Ports.Extractor;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Hash_A : constant String := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
   Hash_B : constant String := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

   Registry : constant String :=
     "{""ext"": {""repo"": ""u"", ""scope"": ""s""}}";

   function Make_Tag
     (Name, Kind : String; Line : Natural; Which : Core.Graph_Model.Role)
      return Core.Graph_Model.Tag is
     (Name => To_Unbounded_String (Name), Kind => To_Unbounded_String (Kind),
      Which      => Which, Line => Line,
      Expression => To_Unbounded_String (Name & "()"));

   function One_Tag (Tag : Core.Graph_Model.Tag) return Port.Outcome is
      Tags : Core.Tag_Payload.Tag_Vectors.Vector;
   begin
      Tags.Append (Tag);
      return (Kind => Port.With_Tags, Tags => Tags);
   end One_Tag;

   procedure Prepare (F : aliased in out Fixture; Dir : Scratch) is
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Put_Config (Dir, "synapse-grammars.conf", Registry);
      Ada.Directories.Create_Path (Path (Dir, "repo"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "paths.tsv"),
         "a.ext" & HT & Hash_A & LF & "b.ext" & HT & Hash_B & LF & "c.none" &
         HT & Hash_A & LF & HT & Hash_A & LF & "bad line" & LF & "d.ext" & HT &
         "zz" & LF);
      F.Extractors.Source.Script
        ("a.ext",
         One_Tag (Make_Tag ("alpha", "function", 4, Core.Graph_Model.Def)));
      F.Extractors.Source.Script
        ("b.ext",
         One_Tag (Make_Tag ("beta", "call", 9, Core.Graph_Model.Ref)));
      F.Extractors.Source.Script ("c.none", (Kind => Port.Unsupported));
   end Prepare;

   function Update_Args (Dir : Scratch) return Lists.Vector is
     (Args
        ("--repo-root", Path (Dir, "repo"), "--cache", Path (Dir, "c.bin"),
         "--paths", Path (Dir, "paths.tsv")));

   procedure Update_Tags_What_The_Cache_Lacks_And_Records_The_Rest
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Assert
        (Run (Env (F), Update_Args (Dir)) = 0,
         "success: " & F.Console.Err_Text);
      Assert (F.Extractors.Source.Calls = 1, "one extraction for every path");
      Assert
        (Natural (F.Extractors.Source.Seen.Length) = 3,
         "the three well formed lines");
      declare
         Cache : Synapse.Adapters.Tags_Cache.Cache;
         Got   : Synapse.Adapters.Tags_Cache.Maybe_Value;
      begin
         Synapse.Adapters.Tags_Cache.Open (Cache, Path (Dir, "c.bin"));
         Assert
           (Synapse.Adapters.Tags_Cache.Count (Cache) = 3, "three records");
         Got := Synapse.Adapters.Tags_Cache.Get (Cache, "c.none");
         Assert
           (Got.Found and then Got.Value.Unsupported,
            "unsupported is remembered");
         Got := Synapse.Adapters.Tags_Cache.Get (Cache, "a.ext");
         Assert (Got.Found and then not Got.Value.Unsupported, "tagged");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Update_Tags_What_The_Cache_Lacks_And_Records_The_Rest;

   procedure Update_Asks_Only_For_What_Changed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Assert (Run (Env (F), Update_Args (Dir)) = 0, "first");
      Assert (Run (Env (F), Update_Args (Dir)) = 0, "second");
      Assert (F.Extractors.Source.Calls = 1, "nothing to do the second time");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "paths.tsv"),
         "a.ext" & HT & Hash_B & LF & "b.ext" & HT & Hash_B & LF);
      Assert (Run (Env (F), Update_Args (Dir)) = 0, "third");
      Assert (F.Extractors.Source.Calls = 2, "a changed hash is tagged again");
      Assert
        (Natural (F.Extractors.Source.Seen.Length) = 4, "and only that path");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Update_Asks_Only_For_What_Changed;

   procedure Update_Creates_The_Cache_When_There_Is_Nothing_To_Tag
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "paths.tsv"), "garbage" & LF);
      Assert (Run (Env (F), Update_Args (Dir)) = 0, "success");
      Assert
        (Ada.Directories.Exists (Path (Dir, "c.bin")),
         "the cache exists afterwards");
      Assert (F.Extractors.Source.Calls = 0, "nothing extracted");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Update_Creates_The_Cache_When_There_Is_Nothing_To_Tag;

   procedure Update_Says_When_It_Cannot (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Assert
        (Run
           (Env (F),
            Args
              ("--repo-root", Path (Dir, "nope"), "--cache",
               Path (Dir, "c.bin"), "--paths", Path (Dir, "paths.tsv"))) =
         1,
         "no repo root");
      Assert
        (Run
           (Env (F),
            Args
              ("--repo-root", Path (Dir, "repo"), "--cache",
               Path (Dir, "c.bin"), "--paths", Path (Dir, "gone.tsv"))) =
         1,
         "no list");
      Put_Config (Dir, "synapse-grammars.conf", "not json");
      Assert (Run (Env (F), Update_Args (Dir)) = 1, "an unreadable registry");
      Assert
        (F.Console.Err_Text =
         "synapse-tags-cache: no such repo root: " & Path (Dir, "nope") & LF &
         "synapse-tags-cache: unreadable paths file: " &
         Path (Dir, "gone.tsv") & LF &
         "synapse-tags-cache: could not bring the cache up to date" & LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Update_Says_When_It_Cannot;

   procedure Dump_Says_What_The_Cache_Holds (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Assert (Run (Env (F), Update_Args (Dir)) = 0, "update");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--dump", Path (Dir, "c.bin"))) = 0, "dump");
      Assert
        (F.Console.Out_Text =
         "H" & HT & "a.ext" & HT & Hash_A & LF & "P" & HT & "a.ext" & LF &
         "T" & HT & "a.ext" & HT & "alpha" & HT & " | function" & HT &
         "def (4, 0) - (4, 0) `alpha()`" & LF & "H" & HT & "b.ext" & HT &
         Hash_B & LF & "P" & HT & "b.ext" & LF & "T" & HT & "b.ext" & HT &
         "beta" & HT & " | call" & HT & "ref (9, 0) - (9, 0) `beta()`" & LF &
         "H" & HT & "c.none" & HT & Hash_A & LF & "U" & HT & "c.none" & LF,
         "in path order: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Dump_Says_What_The_Cache_Holds;

   procedure Load_Is_The_Inverse_Of_Dump (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Assert (Run (Env (F), Update_Args (Dir)) = 0, "update");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--dump", Path (Dir, "c.bin"))) = 0, "dump");
      declare
         Dumped : constant String := F.Console.Out_Text;
      begin
         F.Console.Clear;
         F.Console.Set_Stdin (Dumped);
         Assert
           (Run (Env (F), Args ("--load", Path (Dir, "d.bin"))) = 0, "load");
         F.Console.Clear;
         Assert
           (Run (Env (F), Args ("--dump", Path (Dir, "d.bin"))) = 0,
            "dump again");
         Assert (F.Console.Out_Text = Dumped, "the same text");
         Assert
           (Synapse.Adapters.File_Bytes.Read (Path (Dir, "c.bin"), 100_000) =
            Synapse.Adapters.File_Bytes.Read (Path (Dir, "d.bin"), 100_000),
            "and the same file");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Load_Is_The_Inverse_Of_Dump;

   procedure Load_Ignores_What_It_Cannot_Place (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      F.Console.Set_Stdin
        ("T" & HT & "unknown" & HT & "x | k" & HT & "def (1, 0) - (1, 0) `e`" &
         LF & "H" & HT & "p" & HT & Hash_A & LF & "U" & HT & "ghost" & LF &
         "?" & HT & "x" & LF & "x" & LF & "H" & HT & "q" & HT & "short" & LF &
         "T" & HT & "p" & HT & "not a tag line" & LF);
      Assert (Run (Env (F), Args ("--load", Path (Dir, "d.bin"))) = 0, "load");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--dump", Path (Dir, "d.bin"))) = 0, "dump");
      Assert
        (F.Console.Out_Text =
         "H" & HT & "p" & HT & Hash_A & LF & "P" & HT & "p" & LF,
         "only the one entry: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Load_Ignores_What_It_Cannot_Place;

   procedure Refs_Prints_The_Rows_Of_The_Cache (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Assert (Run (Env (F), Update_Args (Dir)) = 0, "update");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--refs", Path (Dir, "c.bin"))) = 0, "refs");
      Assert
        (F.Console.Out_Text =
         "alpha" & HT & "def" & HT & "function" & HT & "a.ext:4" & HT &
         "alpha()" & LF & "beta" & HT & "ref" & HT & "call" & HT & "b.ext:9" &
         HT & "beta()" & LF,
         "path order, not sorted: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Refs_Prints_The_Rows_Of_The_Cache;

   procedure A_Cache_That_Will_Not_Read_Is_Reported_By_Dump_And_Refs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "bad.bin"), [1 .. 100 => 'x']);
      Assert
        (Run (Env (F), Args ("--dump", Path (Dir, "bad.bin"))) = 1, "dump");
      Assert
        (Run (Env (F), Args ("--refs", Path (Dir, "bad.bin"))) = 1, "refs");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "synapse-tags-cache: unreadable cache (NotACache): ") =
         1,
         "named: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Cache_That_Will_Not_Read_Is_Reported_By_Dump_And_Refs;

   procedure Tags_Cache_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "none");
      Assert (Run (Env (F), Args ("--repo-root", "x")) = 2, "some");
      Assert (Run (Env (F), Args ("--cache")) = 2, "dangling");
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("--dump", "x", "--help")) = 0,
         "help beats the rest");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse tags-cache --repo-root") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Tags_Cache_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Tags_Cache");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Update_Tags_What_The_Cache_Lacks_And_Records_The_Rest'Access,
         "Update tags what the cache lacks and records the rest");
      Register_Routine
        (T, Update_Asks_Only_For_What_Changed'Access,
         "Update asks only for what changed");
      Register_Routine
        (T, Update_Creates_The_Cache_When_There_Is_Nothing_To_Tag'Access,
         "Update creates the cache when there is nothing to tag");
      Register_Routine
        (T, Update_Says_When_It_Cannot'Access, "Update says when it cannot");
      Register_Routine
        (T, Dump_Says_What_The_Cache_Holds'Access,
         "Dump says what the cache holds");
      Register_Routine
        (T, Load_Is_The_Inverse_Of_Dump'Access, "Load is the inverse of dump");
      Register_Routine
        (T, Load_Ignores_What_It_Cannot_Place'Access,
         "Load ignores what it cannot place");
      Register_Routine
        (T, Refs_Prints_The_Rows_Of_The_Cache'Access,
         "Refs prints the rows of the cache");
      Register_Routine
        (T, A_Cache_That_Will_Not_Read_Is_Reported_By_Dump_And_Refs'Access,
         "A cache that will not read is reported by dump and refs");
      Register_Routine
        (T, Tags_Cache_Arguments'Access, "Tags cache arguments");
   end Register_Tests;

end Synapse.Commands.Tags_Cache.Tests;
