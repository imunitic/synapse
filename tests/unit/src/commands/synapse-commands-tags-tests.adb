with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.Graph_Model;
with Synapse.Core.Tag_Payload;
with Synapse.Ports.Extractor;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with Ada.Strings.Fixed;
with AUnit.Assertions;

package body Synapse.Commands.Tags.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   package Port renames Synapse.Ports.Extractor;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Registry : constant String :=
     "{""ext"": {""repo"": ""u"", ""scope"": ""s""}, " &
     """zed"": {""repo"": ""u"", ""scope"": ""s""}, " &
     """off"": {""unsupported"": true}}";

   function Make_Tag
     (Name, Kind : String; Line : Natural := 3; Expr : String := "x")
      return Core.Graph_Model.Tag is
     (Name => To_Unbounded_String (Name), Kind => To_Unbounded_String (Kind),
      Which      => Core.Graph_Model.Def, Line => Line,
      Expression => To_Unbounded_String (Expr));

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
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "a.ext"), "source" & LF);
   end Prepare;

   procedure Single_Prints_A_Tag_As_Tree_Sitter_Does
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      F.Extractors.Source.Script
        (Path (Dir, "a.ext"),
         One_Tag (Make_Tag ("Token", "class", 7, "public class Token {")));
      Assert
        (Run (Env (F), Args (Path (Dir, "a.ext"))) = 0,
         "success: " & F.Console.Err_Text);
      Assert
        (F.Console.Out_Text =
         "Token     " & HT & " | class   " & HT &
         "def (7, 0) - (7, 5) `public class Token {`" & LF,
         "padded name and kind: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Single_Prints_A_Tag_As_Tree_Sitter_Does;

   procedure Single_Does_Not_Cut_A_Long_Name_And_Cuts_The_Expression
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      F.Extractors.Source.Script
        (Path (Dir, "a.ext"),
         One_Tag
           (Make_Tag
              ("AVeryLongTagName", "implementation", 1,
               [1 .. 179 => 'e'] & "  tail")));
      Assert (Run (Env (F), Args (Path (Dir, "a.ext"))) = 0, "success");
      Assert
        (F.Console.Out_Text =
         "AVeryLongTagName" & HT & " | implementation" & HT &
         "def (1, 0) - (1, 16) `" & [1 .. 179 => 'e'] & "`" & LF,
         "cut at 180 bytes and trimmed: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Single_Does_Not_Cut_A_Long_Name_And_Cuts_The_Expression;

   procedure Single_Cuts_An_Expression_Only_Past_180_Bytes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      F.Extractors.Source.Script
        (Path (Dir, "a.ext"),
         One_Tag (Make_Tag ("n", "k", 1, [1 .. 181 => 'x'])));
      Assert (Run (Env (F), Args (Path (Dir, "a.ext"))) = 0, "181");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text, "`" & [1 .. 180 => 'x'] & "`") >
         0,
         "one byte too many is cut");
      F.Console.Clear;
      F.Extractors.Source.Script
        (Path (Dir, "a.ext"),
         One_Tag (Make_Tag ("n", "k", 1, [1 .. 180 => 'x'])));
      Assert (Run (Env (F), Args (Path (Dir, "a.ext"))) = 0, "180");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text, "`" & [1 .. 180 => 'x'] & "`") >
         0,
         "exactly 180 stays");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Single_Cuts_An_Expression_Only_Past_180_Bytes;

   procedure Single_Answers_1_For_An_Unusable_Grammar_And_2_For_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "a.off"), "x");
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "a.new"), "x");
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "plain"), "x");
      Assert
        (Run (Env (F), Args (Path (Dir, "a.off"))) = 1, "unsupported entry");
      Assert (Run (Env (F), Args (Path (Dir, "a.new"))) = 2, "no entry");
      Assert (Run (Env (F), Args (Path (Dir, "plain"))) = 1, "no extension");
      Assert (F.Extractors.Source.Calls = 0, "the extractor is not asked");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Single_Answers_1_For_An_Unusable_Grammar_And_2_For_None;

   procedure Single_Says_When_The_File_Is_Missing_Or_Cannot_Be_Tagged
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Assert (Run (Env (F), Args (Path (Dir, "gone.ext"))) = 1, "missing");
      Assert
        (F.Console.Err_Text =
         "synapse-tags: no such file: " & Path (Dir, "gone.ext") & LF,
         "the message");
      F.Extractors.Source.Script
        (Path (Dir, "a.ext"), (Kind => Port.Unsupported));
      Assert
        (Run (Env (F), Args (Path (Dir, "a.ext"))) = 1,
         "no grammar could be built");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Single_Says_When_The_File_Is_Missing_Or_Cannot_Be_Tagged;

   procedure Batch_Prints_Each_Path_With_Its_Tags (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "b.ext"), "x");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "list.txt"),
         " a.ext " & LF & "b.ext" & ASCII.CR & LF & LF & "c.zed" & LF);
      F.Extractors.Source.Script
        ("a.ext", One_Tag (Make_Tag ("A", "function", 2)));
      F.Extractors.Source.Script
        ("b.ext", (Kind => Port.With_Tags, Tags => <>));
      F.Extractors.Source.Script ("c.zed", (Kind => Port.Unsupported));
      Assert
        (Run (Env (F), Args ("--paths", Path (Dir, "list.txt"))) = 0,
         "success");
      Assert
        (F.Console.Out_Text =
         "a.ext" & LF & HT & "A         " & HT & " | function" & HT &
         "def (2, 0) - (2, 1) `x`" & LF & "b.ext" & LF,
         "a file that parsed to nothing keeps its line, an unsupported one has none: " &
         F.Console.Out_Text);
      Assert (F.Extractors.Source.Calls = 1, "one batch");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Batch_Prints_Each_Path_With_Its_Tags;

   procedure Batch_Fails_When_No_File_Could_Be_Tagged_Or_The_List_Is_Unusable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "list.txt"), "a.ext" & LF);
      F.Extractors.Source.Script ("a.ext", (Kind => Port.Unsupported));
      Assert
        (Run (Env (F), Args ("--paths", Path (Dir, "list.txt"))) = 1,
         "none usable");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "blank.txt"), " " & LF & LF);
      Assert
        (Run (Env (F), Args ("--paths", Path (Dir, "blank.txt"))) = 1,
         "no paths");
      Assert
        (Run (Env (F), Args ("--paths", Path (Dir, "gone.txt"))) = 1,
         "unreadable");
      Assert (Run (Env (F), Args ("--paths")) = 1, "no list file");
      Assert
        (F.Console.Err_Text =
         "synapse-tags: unreadable paths file: " & Path (Dir, "gone.txt") & LF,
         "the message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Batch_Fails_When_No_File_Could_Be_Tagged_Or_The_List_Is_Unusable;

   procedure List_Extensions_Prints_The_Usable_Ones_Sorted
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Assert (Run (Env (F), Args ("--list-extensions")) = 0, "success");
      Assert
        (F.Console.Out_Text = "ext" & LF & "zed" & LF,
         "usable only: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end List_Extensions_Prints_The_Usable_Ones_Sorted;

   procedure The_Registry_Must_Be_Readable_And_A_Home_Must_Exist
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("a.ext")) = 1, "no home");
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Put_Config (Dir, "synapse-grammars.conf", "not json");
      Assert (Run (Env (F), Args ("a.ext")) = 1, "malformed registry");
      Assert
        (F.Console.Err_Text =
         "synapse-tags: $HOME is not set" & LF &
         "synapse-tags: unreadable grammar registry: " &
         Path (Dir, "home/.claude/synapse-grammars.conf") & LF,
         "both messages: " & F.Console.Err_Text);
      Put_Config (Dir, "synapse-grammars.conf", Registry);
      Put_Config (Dir, "synapse-kind-synonyms.conf", "not json");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("a.ext")) = 1, "malformed rules");
      Assert
        (F.Console.Err_Text =
         "synapse-tags: unreadable kind-synonyms conf: " &
         Path (Dir, "home/.claude/synapse-kind-synonyms.conf") & LF,
         "the rules: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Registry_Must_Be_Readable_And_A_Home_Must_Exist;

   procedure A_Missing_Registry_Is_An_Empty_One (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Assert (Run (Env (F), Args ("--list-extensions")) = 0, "success");
      Assert (F.Console.Out_Text = "", "nothing usable");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Missing_Registry_Is_An_Empty_One;

   procedure Tags_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "none");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("-h")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse tags <file>") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Tags_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Tags");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Single_Prints_A_Tag_As_Tree_Sitter_Does'Access,
         "Single prints a tag as tree-sitter does");
      Register_Routine
        (T, Single_Does_Not_Cut_A_Long_Name_And_Cuts_The_Expression'Access,
         "Single does not cut a long name and cuts the expression");
      Register_Routine
        (T, Single_Cuts_An_Expression_Only_Past_180_Bytes'Access,
         "Single cuts an expression only past 180 bytes");
      Register_Routine
        (T, Single_Answers_1_For_An_Unusable_Grammar_And_2_For_None'Access,
         "Single answers 1 for an unusable grammar and 2 for none");
      Register_Routine
        (T, Single_Says_When_The_File_Is_Missing_Or_Cannot_Be_Tagged'Access,
         "Single says when the file is missing or cannot be tagged");
      Register_Routine
        (T, Batch_Prints_Each_Path_With_Its_Tags'Access,
         "Batch prints each path with its tags");
      Register_Routine
        (T,
         Batch_Fails_When_No_File_Could_Be_Tagged_Or_The_List_Is_Unusable'
           Access,
         "Batch fails when no file could be tagged or the list is unusable");
      Register_Routine
        (T, List_Extensions_Prints_The_Usable_Ones_Sorted'Access,
         "List extensions prints the usable ones sorted");
      Register_Routine
        (T, The_Registry_Must_Be_Readable_And_A_Home_Must_Exist'Access,
         "The registry must be readable and a home must exist");
      Register_Routine
        (T, A_Missing_Registry_Is_An_Empty_One'Access,
         "A missing registry is an empty one");
      Register_Routine (T, Tags_Arguments'Access, "Tags arguments");
   end Register_Tests;

end Synapse.Commands.Tags.Tests;
