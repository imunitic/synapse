with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with Synapse.Adapters.Dynamic_Libraries;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.System_Process;
with Synapse.Core.Graph_Model;
with Synapse.Core.Kind_Synonyms;
with Synapse.Test_Grammar_Repos;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Tree_Sitter.Extractor.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;
   use type Ada.Containers.Count_Type;
   use type Port.Outcome_Kind;

   package Registry_Types renames Synapse.Core.Grammar_Registry;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Real_Runner : aliased Adapters.System_Process.System_Runner;
   Loader      : aliased Dynamic_Libraries.System_Loader;

   No_Rules : Core.Kind_Synonyms.Rule_List;

   Reports : Unbounded_String;

   procedure Capture (Message : String) is
   begin
      Append (Reports, Message & LF);
   end Capture;

   function Count_Of (Text, Part : String) return Natural is
      Found : Natural  := 0;
      From  : Positive := Text'First;
      At_I  : Natural;
   begin
      while From <= Text'Last loop
         At_I := Ada.Strings.Fixed.Index (Text (From .. Text'Last), Part);
         exit when At_I = 0;
         Found := Found + 1;
         From  := At_I + Part'Length;
      end loop;
      return Found;
   end Count_Of;

   function Reported return String is (To_String (Reports));

   function Paths_Of
     (A, B, C, D, E : String := "") return Core.Text_Lists.Vector
   is
      Result : Core.Text_Lists.Vector;

      procedure Add (P : String) is
      begin
         if P /= "" then
            Result.Append (To_Unbounded_String (P));
         end if;
      end Add;
   begin
      Add (A);
      Add (B);
      Add (C);
      Add (D);
      Add (E);
      return Result;
   end Paths_Of;

   --  A tagged file's tags, one entry each: name, kind, role and line.
   function Tags_Of (O : Port.Outcome) return String is
      Text : Unbounded_String;
   begin
      if O.Kind = Port.Unsupported then
         return "unsupported";
      end if;
      for Item of O.Tags loop
         Append
           (Text,
            To_String (Item.Name) & ":" & To_String (Item.Kind) & ":" &
            Core.Graph_Model.Image (Item.Which) & ":" &
            Ada.Strings.Fixed.Trim
              (Natural'Image (Item.Line), Ada.Strings.Left) &
            ";");
      end loop;
      return To_String (Text);
   end Tags_Of;

   Function_Query : constant String :=
     "(function_declaration name: (identifier) @name) @definition.function";

   function Registry_Of
     (Dir : Scratch; Extension, Repo_Name, Extra : String)
      return Registry_Types.Registry is
     (Registry_Types.Parse
        ("{""" & Extension & """:{""repo"":""" & Path (Dir, Repo_Name) &
         """,""scope"":""source.x""" & Extra & "}}"));

   --  Tags one batch with a fresh extractor.
   function Extracted
     (Dir      : Scratch; Registry : Registry_Types.Registry;
      Paths    : Core.Text_Lists.Vector;
      Rules    : Core.Kind_Synonyms.Rule_List := No_Rules;
      Override : Registry_Types.Maybe_Text    := (Found => False))
      return Port.Outcome_Vectors.Vector
   is
      Ex : Tagging_Extractor (Real_Runner'Access, Loader'Access);
   begin
      Configure
        (Ex, Registry, Path (Dir, "grammars"), Rules, 5, Override,
         Capture'Access);
      return Ex.Extract (Path (Dir, "work"), Paths);
   end Extracted;

   procedure Write_Work (Dir : Scratch; Name, Text : String) is
   begin
      Ada.Directories.Create_Path (Path (Dir, "work"));
      File_Bytes.Write (Path (Dir, "work/" & Name), Text);
   end Write_Work;

   ---------------------------------------------------------------------------
   --  Extensions that cannot be used
   ---------------------------------------------------------------------------

   procedure An_Unregistered_Extension_Is_Reported_Once_Then_Skipped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Ex  : Tagging_Extractor (Real_Runner'Access, Loader'Access);
      Got : Port.Outcome_Vectors.Vector;
   begin
      Reports := Null_Unbounded_String;
      Configure
        (Ex, Registry_Types.Parse ("{}"), Path (Dir, "g"), No_Rules, 5,
         (Found => False), Capture'Access);
      Got := Ex.Extract (".", Paths_Of ("a.zz", "b.zz"));
      Assert
        (Got (1).Kind = Port.Unsupported
         and then Got (2).Kind = Port.Unsupported,
         "both skipped");
      Assert
        (Count_Of (Reported, "no grammar registered for .zz") = 1,
         "reported once for two files");
      Assert (Ex.Resolved_Extensions = 1, "one resolution, cached");
      Got := Ex.Extract (".", Paths_Of ("c.zz"));
      Assert
        (Count_Of (Reported, "no grammar") = 1,
         "and not again on a later call");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Unregistered_Extension_Is_Reported_Once_Then_Skipped;

   procedure A_File_With_No_Extension_Is_Unsupported_Without_A_Lookup
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Ex  : Tagging_Extractor (Real_Runner'Access, Loader'Access);
      Got : Port.Outcome_Vectors.Vector;
   begin
      Reports := Null_Unbounded_String;
      Configure
        (Ex, Registry_Types.Parse ("{}"), Path (Dir, "g"), No_Rules, 5,
         (Found => False), Capture'Access);
      Got := Ex.Extract (".", Paths_Of ("Makefile", "dir.d/README"));
      Assert
        (Got (1).Kind = Port.Unsupported
         and then Got (2).Kind = Port.Unsupported,
         "unsupported");
      Assert
        (Reported = "" and then Ex.Resolved_Extensions = 0,
         "the registry was not asked");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_File_With_No_Extension_Is_Unsupported_Without_A_Lookup;

   procedure An_Extension_Marked_Unsupported_Is_Reported_Once
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Reports := Null_Unbounded_String;
      Got     :=
        Extracted
          (Dir, Registry_Types.Parse ("{""sh"":{""unsupported"":true}}"),
           Paths_Of ("a.sh", "b.sh"));
      Assert (Got (1).Kind = Port.Unsupported, "skipped");
      Assert (Count_Of (Reported, "is marked unsupported") = 1, "once");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Extension_Marked_Unsupported_Is_Reported_Once;

   procedure A_Grammar_That_Cannot_Be_Fetched_Is_Reported_Once_With_Its_Reason
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Ex  : Tagging_Extractor (Real_Runner'Access, Loader'Access);
      Got : Port.Outcome_Vectors.Vector;
   begin
      Reports := Null_Unbounded_String;
      Write_Work (Dir, "a.f3", "fn foo()");
      Configure
        (Ex, Registry_Of (Dir, "f3", "tree-sitter-absent", ""),
         Path (Dir, "g"), No_Rules, 5, (Found => False), Capture'Access);
      Got := Ex.Extract (Path (Dir, "work"), Paths_Of ("a.f3", "a.f3"));
      Assert
        (Got (1).Kind = Port.Unsupported
         and then Got (2).Kind = Port.Unsupported,
         "skipped");
      Assert
        (Count_Of (Reported, "grammar for .f3 is not usable") = 1,
         "reported once");
      Assert (Count_Of (Reported, "CLONE_FAILED") = 1, "with the reason");
      Got := Ex.Extract (Path (Dir, "work"), Paths_Of ("a.f3"));
      Assert
        (Count_Of (Reported, "not usable") = 1,
         "the failure is remembered and not retried");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Grammar_That_Cannot_Be_Fetched_Is_Reported_Once_With_Its_Reason;

   ---------------------------------------------------------------------------
   --  Tagging
   ---------------------------------------------------------------------------

   procedure Files_Are_Tagged_One_Outcome_Per_Path_In_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Reports := Null_Unbounded_String;
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake3", "fake3", Tags_Scm => Function_Query);
      Write_Work (Dir, "a.f3", "fn foo()" & LF & "fn bar()" & LF);
      Write_Work (Dir, "empty.f3", "");
      Ada.Directories.Create_Path (Path (Dir, "elsewhere"));
      File_Bytes.Write (Path (Dir, "elsewhere/c.f3"), "fn baz()");
      Got :=
        Extracted
          (Dir, Registry_Of (Dir, "f3", "tree-sitter-fake3", ""),
           Paths_Of
             ("a.f3", "empty.f3", "missing.f3", "Makefile",
               Path (Dir, "elsewhere/c.f3")));
      Assert (Natural (Got.Length) = 5, "one per path");
      Assert
        (Tags_Of (Got (1)) = "foo:function:def:0;bar:function:def:1;",
         "tagged, in order");
      Assert
        (Got (2).Kind = Port.With_Tags and then Got (2).Tags.Is_Empty,
         "a file that parses to nothing is tagged with none");
      Assert (Got (3).Kind = Port.Unsupported, "a file that is not there");
      Assert (Got (4).Kind = Port.Unsupported, "no extension");
      Assert
        (Tags_Of (Got (5)) = "baz:function:def:0;",
         "an absolute path is used as it is");
      Assert (Reported = "", "nothing went wrong");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Files_Are_Tagged_One_Outcome_Per_Path_In_Order;

   procedure A_Large_Batch_Gets_One_Outcome_Each (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      Paths : Core.Text_Lists.Vector;
   begin
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake3", "fake3", Tags_Scm => Function_Query);
      for I in 1 .. 40 loop
         declare
            Name : constant String :=
              "f" &
              Ada.Strings.Fixed.Trim (Integer'Image (I), Ada.Strings.Left) &
              ".f3";
         begin
            Write_Work (Dir, Name, "fn n" & Integer'Image (I) & "()");
            Paths.Append (To_Unbounded_String (Name));
         end;
      end loop;
      declare
         Got : constant Port.Outcome_Vectors.Vector :=
           Extracted
             (Dir, Registry_Of (Dir, "f3", "tree-sitter-fake3", ""), Paths);
      begin
         Assert (Got.Length = Paths.Length, "one each");
         for O of Got loop
            Assert
              (O.Kind = Port.With_Tags and then O.Tags.Length = 1,
               "each tagged");
         end loop;
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Large_Batch_Gets_One_Outcome_Each;

   procedure A_Query_File_In_The_Override_Directory_Wins
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake3", "fake3", Tags_Scm => Function_Query);
      Write_Work (Dir, "a.f3", "fn foo()");
      Ada.Directories.Create_Path (Path (Dir, "queries"));
      File_Bytes.Write
        (Path (Dir, "queries/f3.scm"),
         "(function_declaration name: (identifier) @name) @definition.method");
      Got :=
        Extracted
          (Dir, Registry_Of (Dir, "f3", "tree-sitter-fake3", ""),
           Paths_Of ("a.f3"),
           Override =>
             (Found => True,
              Value => To_Unbounded_String (Path (Dir, "queries"))));
      Assert
        (Tags_Of (Got (1)) = "foo:method:def:0;",
         "the person's query, not the repository's");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Query_File_In_The_Override_Directory_Wins;

   Reference_Query : constant String :=
     "(struct_item (identifier) @name) @reference.type";

   Local_Query : constant String :=
     "(function_declaration name: (identifier) @local.definition.function)";

   procedure References_Bound_In_The_Same_File_Are_Dropped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake3", "fake3", Tags_Scm => Reference_Query,
         Locals_Scm                                         => Local_Query);
      Write_Work (Dir, "a.f3", "fn foo()" & LF & "struct foo{}");
      Write_Work (Dir, "b.f3", "fn other()" & LF & "struct foo{}");
      Got :=
        Extracted
          (Dir, Registry_Of (Dir, "f3", "tree-sitter-fake3", ""),
           Paths_Of ("a.f3", "b.f3"));
      Assert (Tags_Of (Got (1)) = "", "bound in the file: dropped");
      Assert (Tags_Of (Got (2)) = "foo:type:ref:1;", "not bound: kept");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end References_Bound_In_The_Same_File_Are_Dropped;

   procedure A_Locals_File_In_The_Override_Directory_Replaces_The_Repositorys
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake3", "fake3", Tags_Scm => Reference_Query,
         Locals_Scm => "(struct_item (identifier) @local.reference)");
      Write_Work (Dir, "a.f3", "fn foo()" & LF & "struct foo{}");
      Ada.Directories.Create_Path (Path (Dir, "queries"));
      File_Bytes.Write (Path (Dir, "queries/f3.locals.scm"), Local_Query);
      Got :=
        Extracted
          (Dir, Registry_Of (Dir, "f3", "tree-sitter-fake3", ""),
           Paths_Of ("a.f3"),
           Override =>
             (Found => True,
              Value => To_Unbounded_String (Path (Dir, "queries"))));
      Assert
        (Tags_Of (Got (1)) = "",
         "the override's locals filter, not the repository's");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Locals_File_In_The_Override_Directory_Replaces_The_Repositorys;

   procedure A_Locals_Entry_Reads_Locals_Scm_Through_The_Kind_Rules
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir   : constant Scratch                      := Make;
      Rules : constant Core.Kind_Synonyms.Rule_List :=
        Core.Kind_Synonyms.Parse
          ("[{""match"":""function"",""kind"":""routine""}]");
      Got   : Port.Outcome_Vectors.Vector;
   begin
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake3", "fake3", Locals_Scm => Local_Query);
      Write_Work (Dir, "a.f3", "fn foo()");
      Got :=
        Extracted
          (Dir,
           Registry_Of
             (Dir, "f3", "tree-sitter-fake3", ",""queries"":""locals"""),
           Paths_Of ("a.f3"), Rules);
      Assert
        (Tags_Of (Got (1)) = "foo:routine:def:0;",
         "the kind comes through the rules");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Locals_Entry_Reads_Locals_Scm_Through_The_Kind_Rules;

   procedure A_Generated_Entry_Is_Tagged_From_Its_Node_Types
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake_nested", "fake_nested");
      Write_Work (Dir, "a.nst", "wrap var foo" & LF & "outer D { inner E }");
      Got :=
        Extracted
          (Dir,
           Registry_Of
             (Dir, "nst", "tree-sitter-fake_nested",
              ",""queries"":""generated"""),
           Paths_Of ("a.nst"));
      Assert
        (Tags_Of (Got (1)) =
         "foo:function:def:0;D:function:def:1;" & "E:function:def:1;",
         "classified from node-types.json and walked");
      Assert (Reported = "", "nothing went wrong");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Generated_Entry_Is_Tagged_From_Its_Node_Types;

   ---------------------------------------------------------------------------
   --  Query sources that are missing or wrong
   ---------------------------------------------------------------------------

   procedure A_Missing_Query_File_Makes_The_Extension_Unusable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Reports := Null_Unbounded_String;
      Test_Grammar_Repos.Make (Path (Dir), "tree-sitter-fake3", "fake3");
      Write_Work (Dir, "a.f3", "fn foo()");
      Got :=
        Extracted
          (Dir, Registry_Of (Dir, "f3", "tree-sitter-fake3", ""),
           Paths_Of ("a.f3"));
      Assert (Got (1).Kind = Port.Unsupported, "unsupported");
      Assert (Count_Of (Reported, "no queries/tags.scm") = 1, "and said so");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Missing_Query_File_Makes_The_Extension_Unusable;

   procedure A_Generated_Entry_With_No_Node_Types_Is_Unusable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Reports := Null_Unbounded_String;
      Test_Grammar_Repos.Make (Path (Dir), "tree-sitter-fake3", "fake3");
      Write_Work (Dir, "a.f3", "fn foo()");
      Got :=
        Extracted
          (Dir,
           Registry_Of
             (Dir, "f3", "tree-sitter-fake3", ",""queries"":""generated"""),
           Paths_Of ("a.f3"));
      Assert
        (Got (1).Kind = Port.Unsupported
         and then Count_Of (Reported, "no src/node-types.json") = 1,
         "named");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Generated_Entry_With_No_Node_Types_Is_Unusable;

   procedure A_Query_That_Does_Not_Compile_Makes_The_Extension_Unusable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Reports := Null_Unbounded_String;
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake3", "fake3",
         Tags_Scm => "(no_such_node) @name");
      Write_Work (Dir, "a.f3", "fn foo()");
      Got :=
        Extracted
          (Dir, Registry_Of (Dir, "f3", "tree-sitter-fake3", ""),
           Paths_Of ("a.f3"));
      Assert
        (Got (1).Kind = Port.Unsupported
         and then Count_Of (Reported, "QUERY_INVALID") = 1,
         "refused, with the reason");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Query_That_Does_Not_Compile_Makes_The_Extension_Unusable;

   procedure A_Query_With_Only_Unevaluable_Predicates_Is_Unusable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Port.Outcome_Vectors.Vector;
   begin
      Reports := Null_Unbounded_String;
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake3", "fake3",
         Tags_Scm => "(" & Function_Query & " (#match? @name ""f""))");
      Write_Work (Dir, "a.f3", "fn foo()");
      Got :=
        Extracted
          (Dir, Registry_Of (Dir, "f3", "tree-sitter-fake3", ""),
           Paths_Of ("a.f3"));
      Assert
        (Got (1).Kind = Port.Unsupported
         and then Count_Of (Reported, "PREDICATE_UNSUPPORTED") = 1,
         "a query that would match nothing is not a file with no symbols");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Query_With_Only_Unevaluable_Predicates_Is_Unusable;

   procedure Taggers_Are_Released_With_The_Extractor
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Test_Grammar_Repos.Make
        (Path (Dir), "tree-sitter-fake3", "fake3", Tags_Scm => Function_Query);
      Write_Work (Dir, "a.f3", "fn foo()");
      for Round in 1 .. 3 loop
         declare
            Got : constant Port.Outcome_Vectors.Vector :=
              Extracted
                (Dir, Registry_Of (Dir, "f3", "tree-sitter-fake3", ""),
                 Paths_Of ("a.f3"));
         begin
            Assert
              (Tags_Of (Got (1)) = "foo:function:def:0;",
               "an extractor made and finalized again, same result");
         end;
      end loop;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Taggers_Are_Released_With_The_Extractor;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Tree_Sitter.Extractor");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Unregistered_Extension_Is_Reported_Once_Then_Skipped'Access,
         "An unregistered extension is reported once, then skipped");
      Register_Routine
        (T, A_File_With_No_Extension_Is_Unsupported_Without_A_Lookup'Access,
         "A file with no extension is unsupported without a lookup");
      Register_Routine
        (T, An_Extension_Marked_Unsupported_Is_Reported_Once'Access,
         "An extension marked unsupported is reported once");
      Register_Routine
        (T,
         A_Grammar_That_Cannot_Be_Fetched_Is_Reported_Once_With_Its_Reason'
           Access,
         "A grammar that cannot be fetched is reported once, with its reason");
      Register_Routine
        (T, Files_Are_Tagged_One_Outcome_Per_Path_In_Order'Access,
         "Files are tagged, one outcome per path, in order");
      Register_Routine
        (T, A_Large_Batch_Gets_One_Outcome_Each'Access,
         "A large batch gets one outcome each");
      Register_Routine
        (T, A_Query_File_In_The_Override_Directory_Wins'Access,
         "A query file in the override directory wins");
      Register_Routine
        (T, References_Bound_In_The_Same_File_Are_Dropped'Access,
         "References bound in the same file are dropped");
      Register_Routine
        (T,
         A_Locals_File_In_The_Override_Directory_Replaces_The_Repositorys'
           Access,
         "A locals file in the override directory replaces the repository's");
      Register_Routine
        (T, A_Locals_Entry_Reads_Locals_Scm_Through_The_Kind_Rules'Access,
         "A locals entry reads locals.scm through the kind rules");
      Register_Routine
        (T, A_Generated_Entry_Is_Tagged_From_Its_Node_Types'Access,
         "A generated entry is tagged from its node types");
      Register_Routine
        (T, A_Missing_Query_File_Makes_The_Extension_Unusable'Access,
         "A missing query file makes the extension unusable");
      Register_Routine
        (T, A_Generated_Entry_With_No_Node_Types_Is_Unusable'Access,
         "A generated entry with no node types is unusable");
      Register_Routine
        (T, A_Query_That_Does_Not_Compile_Makes_The_Extension_Unusable'Access,
         "A query that does not compile makes the extension unusable");
      Register_Routine
        (T, A_Query_With_Only_Unevaluable_Predicates_Is_Unusable'Access,
         "A query with only unevaluable predicates is unusable");
      Register_Routine
        (T, Taggers_Are_Released_With_The_Extractor'Access,
         "Taggers are released with the extractor");
   end Register_Tests;

end Synapse.Adapters.Tree_Sitter.Extractor.Tests;
