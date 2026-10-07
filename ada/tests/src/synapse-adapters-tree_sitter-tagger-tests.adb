with Ada.Strings.Fixed;

with AUnit.Assertions;
with Synapse.Adapters.Dynamic_Libraries;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Tree_Sitter.Grammar;
with Synapse.Core.Grammar_Registry;
with Synapse.Core.Graph_Model;
with Synapse.Core.Kind_Synonyms;
with Synapse.Core.Node_Types;

package body Synapse.Adapters.Tree_Sitter.Tagger.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   package Registry renames Synapse.Core.Grammar_Registry;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Real_Loader : Dynamic_Libraries.System_Loader;

   No_Locals : constant Registry.Maybe_Text := (Found => False);

   function Locals_Of (Text : String) return Registry.Maybe_Text is
     (Found => True, Value => To_Unbounded_String (Text));

   No_Rules : Core.Kind_Synonyms.Rule_List;

   No_Guesses : Core.Node_Types.Guess_Vectors.Vector;

   function Language_Of (Fixture, Symbol : String) return Language is
      Loaded : constant Grammar.Load_Result :=
        Grammar.Load_Language
          (Real_Loader,
           "fixtures/lib/lib" & Fixture & "." & Real_Loader.Extension, Symbol);
   begin
      Assert
        (Grammar.Load_Results.Is_Success (Loaded),
         "the " & Fixture & " fixture loads");
      return Grammar.Load_Results.Value (Loaded);
   end Language_Of;

   function Docstrings return Language is
     (Language_Of ("fake_docstrings", "tree_sitter_fake_docstrings"));

   function Fake3 return Language is
     (Language_Of ("fake3", "tree_sitter_fake3"));

   function Nested return Language is
     (Language_Of ("fake_nested", "tree_sitter_fake_nested"));

   --  What each tag was, one entry each: name, kind, role and line.
   function Describe (Tags : Tag_Vectors.Vector) return String is
      Text : Unbounded_String;
   begin
      for Item of Tags loop
         Append
           (Text,
            To_String (Item.Name) & ":" & To_String (Item.Kind) & ":" &
            Core.Graph_Model.Image (Item.Which) & ":" &
            Ada.Strings.Fixed.Trim
              (Natural'Image (Item.Line), Ada.Strings.Left) &
            ";");
      end loop;
      return To_String (Text);
   end Describe;

   --  Creates a tagger and tags Source with it, or says why it could not.
   function Tagged_By
     (Lang        : Language; Query_Text : String; Source : String;
      Which       : Registry.Query_Source                := Registry.Tags;
      Rules       : Core.Kind_Synonyms.Rule_List         := No_Rules;
      Guesses     : Core.Node_Types.Guess_Vectors.Vector := No_Guesses;
      Locals_Text : Registry.Maybe_Text := No_Locals) return String
   is
      T      : Tagger;
      Status : Create_Status;
   begin
      Create
        (T, Lang, Query_Text, Which, Rules, "test-scope", Guesses, Locals_Text,
         Status);
      if Status /= Created then
         return "create:" & Create_Status'Image (Status);
      end if;
      declare
         Got : constant Tag_Results.Result := Tag_File (T, Source);
      begin
         return
           (if Tag_Results.Is_Success (Got) then
              Describe (Tag_Results.Value (Got))
            else "tag:" & Tag_Error'Image (Tag_Results.Error (Got)));
      end;
   end Tagged_By;

   Function_Query : constant String :=
     "(function_declaration name: (identifier) @name) @definition.function";

   ---------------------------------------------------------------------------
   --  Predicates
   ---------------------------------------------------------------------------

   procedure Predicates_Are_Classified_Into_Skip_Evaluate_And_Refuse
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classify ("strip!") = Directive
         and then Classify ("set!") = Directive,
         "directives");
      Assert
        (Classify ("eq?") = Equal and then Classify ("not-eq?") = Not_Equal
         and then Classify ("any-of?") = Any_Of
         and then Classify ("not-any-of?") = Not_Any_Of,
         "the four");
      Assert (Classify ("match?") = Unevaluable, "needs a regular expression");
      Assert
        (Classify ("is-not?") = Unevaluable
         and then Classify ("something-new") = Unevaluable
         and then Classify ("") = Unevaluable,
         "anything unknown refuses and does not pass");
   end Predicates_Are_Classified_Into_Skip_Evaluate_And_Refuse;

   Two_Functions : constant String := "fn foo()" & LF & "fn bar()" & LF;

   procedure Eq_Keeps_Only_The_Matching_Name (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings, "(" & Function_Query & " (#eq? @name ""foo""))",
            Two_Functions) =
         "foo:function:def:0;",
         "eq");
      Assert
        (Tagged_By
           (Docstrings, "(" & Function_Query & " (#not-eq? @name ""foo""))",
            Two_Functions) =
         "bar:function:def:1;",
         "not-eq");
   end Eq_Keeps_Only_The_Matching_Name;

   procedure Any_Of_Keeps_Only_The_Listed_Names (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings,
            "(" & Function_Query & " (#any-of? @name ""foo"" ""baz""))",
            Two_Functions) =
         "foo:function:def:0;",
         "any-of");
      Assert
        (Tagged_By
           (Docstrings,
            "(" & Function_Query & " (#not-any-of? @name ""foo"" ""baz""))",
            Two_Functions) =
         "bar:function:def:1;",
         "not-any-of");
      Assert
        (Tagged_By
           (Docstrings,
            "(" & Function_Query & " (#any-of? @name ""x"" ""y""))",
            Two_Functions) =
         "",
         "none listed");
   end Any_Of_Keeps_Only_The_Listed_Names;

   procedure Every_Predicate_Of_A_Pattern_Is_Evaluated
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings,
            "(" & Function_Query & " (#any-of? @name ""foo"" ""bar"")" &
            " (#not-eq? @name ""foo""))",
            Two_Functions) =
         "bar:function:def:1;",
         "the second predicate filters too");
      Assert
        (Tagged_By
           (Docstrings,
            "(" & Function_Query & " (#eq? @name ""foo"")" &
            " (#match? @name ""f""))",
            Two_Functions) =
         "create:PREDICATE_UNSUPPORTED",
         "one that cannot be evaluated disables the pattern wherever it is");
   end Every_Predicate_Of_A_Pattern_Is_Evaluated;

   procedure A_Literal_Where_A_Capture_Is_Expected_Is_Refused_Or_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant String :=
        Tagged_By
          (Docstrings, "(" & Function_Query & " (#eq? ""foo"" @name))",
           Two_Functions);
   begin
      Assert
        (Got in "" | "create:QUERY_INVALID",
         "never lets a malformed predicate through: " & Got);
   end A_Literal_Where_A_Capture_Is_Expected_Is_Refused_Or_Fails;

   procedure A_Capture_Can_Be_Compared_With_Another_Capture
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings, "(" & Function_Query & " (#eq? @name @name))",
            Two_Functions) =
         "foo:function:def:0;bar:function:def:1;",
         "a capture equals itself");
      Assert
        (Tagged_By
           (Docstrings, "(" & Function_Query & " (#not-eq? @name @name))",
            Two_Functions) =
         "",
         "and is not unequal to itself");
   end A_Capture_Can_Be_Compared_With_Another_Capture;

   procedure A_Directive_Rewrites_And_Does_Not_Filter
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings, "(" & Function_Query & " (#set! role ""x""))",
            Two_Functions) =
         "foo:function:def:0;bar:function:def:1;",
         "skipped");
   end A_Directive_Rewrites_And_Does_Not_Filter;

   procedure A_Predicate_That_Cannot_Be_Evaluated_Disables_Only_Its_Pattern
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Matching : constant String :=
        "(" & Function_Query & " (#match? @name ""^f""))";
      Plain    : constant String :=
        "(struct_item name: (identifier) @name) @definition.type";
   begin
      Assert
        (Tagged_By
           (Docstrings, Matching & Plain,
            "fn foo()" & LF & "struct Bar {}" & LF) =
         "Bar:type:def:1;",
         "the pattern with `#match?` never matches, the other does");
      Assert
        (Tagged_By (Docstrings, Matching, Two_Functions) =
         "create:PREDICATE_UNSUPPORTED",
         "a query with nothing left that can match is refused");
      Assert
        (Tagged_By
           (Docstrings, "(" & Function_Query & " (#frobnicate? @name))",
            Two_Functions) =
         "create:PREDICATE_UNSUPPORTED",
         "an unknown predicate refuses as well");
   end A_Predicate_That_Cannot_Be_Evaluated_Disables_Only_Its_Pattern;

   ---------------------------------------------------------------------------
   --  The tags convention
   ---------------------------------------------------------------------------

   procedure A_Definition_Is_Tagged_With_Its_Line_And_Trimmed_Source
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant String :=
        Tagged_By
          (Docstrings,
           Function_Query & LF &
           "(struct_item name: (identifier) @name) @definition.type",
           "// doc" & LF & "   fn foo()  " & Character'Val (13) & LF &
           "struct Bar {}");
   begin
      Assert
        (Got = "foo:function:def:1;Bar:type:def:2;",
         "names, kinds, roles and lines as tree-sitter numbers them");
   end A_Definition_Is_Tagged_With_Its_Line_And_Trimmed_Source;

   procedure The_Echoed_Line_Is_The_Whole_Line_Trimmed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Lang   : constant Language := Docstrings;
      Q      : constant String   := Function_Query;
      Tag    : Tagger;
      Status : Create_Status;
   begin
      Create
        (Tag, Lang, Q, Registry.Tags, No_Rules, "s", No_Guesses, No_Locals,
         Status);
      Assert (Status = Created, "created");
      declare
         Got : constant Tag_Results.Result :=
           Tag_File
             (Tag, "// doc" & LF & "  fn foo()  " & Character'Val (13) & LF);
      begin
         Assert
           (Tag_Results.Is_Success (Got)
            and then Natural (Tag_Results.Value (Got).Length) = 1,
            "one tag");
         Assert
           (To_String (Tag_Results.Value (Got) (1).Expression) = "fn foo()",
            "trimmed of blanks and a carriage return");
      end;
   end The_Echoed_Line_Is_The_Whole_Line_Trimmed;

   procedure A_Reference_Capture_Gives_A_Reference
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings,
            "(struct_item name: (identifier) @name) @reference.type",
            "struct Bar {}") =
         "Bar:type:ref:0;",
         "a reference");
   end A_Reference_Capture_Gives_A_Reference;

   procedure A_Match_Without_A_Name_Or_Without_A_Role_Is_Not_A_Tag
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings, "(function_declaration name: (identifier) @name)",
            "fn foo()") =
         "",
         "a name and no role");
      Assert
        (Tagged_By
           (Docstrings, "(function_declaration) @definition.function",
            "fn foo()") =
         "",
         "a role and no name");
   end A_Match_Without_A_Name_Or_Without_A_Role_Is_Not_A_Tag;

   procedure An_Empty_File_Has_No_Tags_And_That_Is_A_Success
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By (Docstrings, Function_Query, "") = "",
         "a file that parses to nothing");
   end An_Empty_File_Has_No_Tags_And_That_Is_A_Success;

   procedure A_Query_That_Does_Not_Compile_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By (Docstrings, "(no_such_node) @name", "fn foo()") =
         "create:QUERY_INVALID",
         "an unknown node type");
      Assert
        (Tagged_By (Docstrings, "(function_declaration", "fn foo()") =
         "create:QUERY_INVALID",
         "a syntax error");
   end A_Query_That_Does_Not_Compile_Is_Refused;

   procedure A_Tagger_That_Was_Not_Created_Does_Not_Tag
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Tag : Tagger;
      Got : constant Tag_Results.Result := Tag_File (Tag, "fn foo()");
   begin
      Assert
        (not Tag_Results.Is_Success (Got)
         and then Tag_Results.Error (Got) = Not_Created,
         "refused, and not an empty answer");
      Assert (not Is_Created (Tag), "not created");
   end A_Tagger_That_Was_Not_Created_Does_Not_Tag;

   ---------------------------------------------------------------------------
   --  The locals convention
   ---------------------------------------------------------------------------

   Locals_Rules : constant Core.Kind_Synonyms.Rule_List :=
     Core.Kind_Synonyms.Parse
       ("[{""match"":""function"",""kind"":""routine""}," &
        "{""match"":"""",""kind"":""binding""}," &
        "{""match"":""scoped"",""scope"":""other"",""kind"":""x""}]");

   procedure A_Local_Definition_Is_Both_Name_And_Role
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings,
            "(function_declaration name: (identifier) " &
            "@local.definition.function)",
            Two_Functions, Registry.Locals, Locals_Rules) =
         "foo:routine:def:0;bar:routine:def:1;",
         "the kind comes through the rules");
   end A_Local_Definition_Is_Both_Name_And_Role;

   procedure A_Bare_Local_Definition_Is_Mapped_By_An_Empty_Spelling
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings,
            "(function_declaration name: (identifier) @local.definition)",
            "fn foo()", Registry.Locals, Locals_Rules) =
         "foo:binding:def:0;",
         "bare");
   end A_Bare_Local_Definition_Is_Mapped_By_An_Empty_Spelling;

   procedure An_Unmapped_Or_Differently_Scoped_Kind_Is_Dropped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings,
            "(function_declaration name: (identifier) @local.definition.nope)",
            "fn foo()", Registry.Locals, Locals_Rules) =
         "",
         "no rule");
      Assert
        (Tagged_By
           (Docstrings,
            "(function_declaration name: (identifier) " &
            "@local.definition.scoped)",
            "fn foo()", Registry.Locals, Locals_Rules) =
         "",
         "a rule for another grammar");
      Assert
        (Tagged_By
           (Docstrings,
            "(function_declaration name: (identifier) " &
            "@local.definition.function)",
            "fn foo()", Registry.Locals) =
         "",
         "no rules at all");
   end An_Unmapped_Or_Differently_Scoped_Kind_Is_Dropped;

   procedure A_Capture_That_Only_Starts_Like_A_Definition_Is_Not_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings,
            "(function_declaration name: (identifier) " &
            "@local.definitions_list)",
            "fn foo()", Registry.Locals, Locals_Rules) =
         "",
         "`definitions_list` is not a definition");
      Assert
        (Tagged_By
           (Docstrings,
            "(function_declaration name: (identifier) @local.reference)",
            "fn foo()", Registry.Locals, Locals_Rules) =
         "",
         "nor is a reference");
   end A_Capture_That_Only_Starts_Like_A_Definition_Is_Not_One;

   ---------------------------------------------------------------------------
   --  References bound in the same file
   ---------------------------------------------------------------------------

   Reference_Query : constant String :=
     "(struct_item (identifier) @name) @reference.type";

   Local_Query : constant String :=
     "(function_declaration name: (identifier) @local.definition.function)";

   procedure A_Reference_That_Matches_A_Local_Definition_Is_Dropped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Fake3, Reference_Query, "fn foo()" & LF & "struct foo{}",
            Locals_Text => Locals_Of (Local_Query)) =
         "",
         "bound in the same file: dropped");
   end A_Reference_That_Matches_A_Local_Definition_Is_Dropped;

   procedure A_Reference_That_Matches_No_Local_Definition_Survives
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Fake3, Reference_Query, "fn other()" & LF & "struct foo{}",
            Locals_Text => Locals_Of (Local_Query)) =
         "foo:type:ref:1;",
         "still a candidate for resolution in another file");
   end A_Reference_That_Matches_No_Local_Definition_Survives;

   procedure A_Grammar_With_No_Locals_Keeps_Every_Reference
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By (Fake3, Reference_Query, "fn foo()" & LF & "struct foo{}") =
         "foo:type:ref:1;",
         "no filtering, not even by accident");
   end A_Grammar_With_No_Locals_Keeps_Every_Reference;

   procedure A_Locals_Query_That_Is_Unusable_Degrades_Without_Refusing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Source : constant String := "fn foo()" & LF & "struct foo{}";
   begin
      Assert
        (Tagged_By
           (Fake3, Reference_Query, Source,
            Locals_Text => Locals_Of ("(this is not valid")) =
         "foo:type:ref:1;",
         "invalid: no filtering");
      Assert
        (Tagged_By
           (Fake3, Reference_Query, Source,
            Locals_Text =>
              Locals_Of
                ("((function_declaration name: (identifier) " &
                 "@local.definition.function) (#match? @x ""a""))")) =
         "foo:type:ref:1;",
         "every pattern disabled: no filtering");
   end A_Locals_Query_That_Is_Unusable_Degrades_Without_Refusing;

   procedure A_Definition_Is_Never_Dropped_As_A_Local_Reference
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Tagged_By
           (Docstrings, Function_Query, "fn foo()",
            Locals_Text =>
              Locals_Of
                ("(function_declaration name: (identifier) " &
                 "@local.definition.function)")) =
         "foo:function:def:0;",
         "only references are filtered");
   end A_Definition_Is_Never_Dropped_As_A_Local_Reference;

   ---------------------------------------------------------------------------
   --  The generated query and the walk
   ---------------------------------------------------------------------------

   function Guess
     (Type_Name, Kind : String; Has_Name : Boolean)
      return Core.Node_Types.Guess is
     (Type_Name => To_Unbounded_String (Type_Name),
      Kind      => To_Unbounded_String (Kind), Has_Name_Field => Has_Name);

   function Fake3_Generated (Source : String) return String is
      Guesses : Core.Node_Types.Guess_Vectors.Vector;
   begin
      Guesses.Append (Guess ("function_declaration", "function", True));
      Guesses.Append (Guess ("struct_item", "struct", False));
      return
        Tagged_By
          (Fake3, Core.Node_Types.Build_Query (Guesses), Source,
           Registry.Generated, Guesses => Guesses);
   end Fake3_Generated;

   procedure The_Query_And_The_Walk_Combine_In_Every_Emptiness_Case
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Fake3_Generated ("") = "", "neither");
      Assert
        (Fake3_Generated ("fn foo()") = "foo:function:def:0;",
         "the query alone");
      Assert
        (Fake3_Generated ("struct Bar{}") = "Bar:struct:def:0;",
         "the walk alone");
      Assert
        (Fake3_Generated ("fn foo()" & LF & "struct Bar{}") =
         "foo:function:def:0;Bar:struct:def:1;",
         "both, the query's first");
   end The_Query_And_The_Walk_Combine_In_Every_Emptiness_Case;

   function Nested_Guesses return Core.Node_Types.Guess_Vectors.Vector is
     (Core.Node_Types.Classify
        (File_Bytes.Read
           ("fixtures/fake_nested/src/node-types.json", 1_048_576),
         No_Rules, "test-scope"));

   function Nested_Tagged (Source : String) return String is
     (Tagged_By
        (Nested, Core.Node_Types.Build_Query (Nested_Guesses), Source,
         Registry.Generated, Guesses => Nested_Guesses));

   procedure The_Fixture_Is_Classified_As_Declarations_With_No_Name_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Guesses : constant Core.Node_Types.Guess_Vectors.Vector :=
        Nested_Guesses;
   begin
      Assert (Natural (Guesses.Length) = 8, "eight declaration-shaped types");
      for G of Guesses loop
         Assert
           (not G.Has_Name_Field,
            To_String (G.Type_Name) & " has no name field");
      end loop;
      Assert
        (Core.Node_Types.Build_Query (Guesses) = "",
         "so the query has nothing in it");
   end The_Fixture_Is_Classified_As_Declarations_With_No_Name_Field;

   procedure Two_Guessed_Declarations_Around_One_Identifier_Are_One_Tag
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Nested_Tagged ("wrap var foo") = "foo:function:def:0;",
         "the outer, once");
   end Two_Guessed_Declarations_Around_One_Identifier_Are_One_Tag;

   procedure A_Name_Three_Levels_Down_Is_Found_And_Four_Is_Not
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Nested_Tagged ("shallow [ [ x") = "x:function:def:0;",
         "three levels");
      Assert (Nested_Tagged ("deep < < < y") = "", "four levels");
   end A_Name_Three_Levels_Down_Is_Found_And_Four_Is_Not;

   procedure A_Node_Is_Never_Its_Own_Name (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Guesses : Core.Node_Types.Guess_Vectors.Vector;
   begin
      Guesses.Append (Guess ("identifier", "var", False));
      Assert
        (Tagged_By
           (Nested, "", "wrap var foo", Registry.Generated,
            Guesses => Guesses) =
         "",
         "an identifier has no identifier below it");
   end A_Node_Is_Never_Its_Own_Name;

   procedure A_Name_Type_Is_Matched_In_Any_Case (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Nested_Tagged ("upper ABC") = "ABC:function:def:0;",
         "a node type spelled NAME");
   end A_Name_Type_Is_Matched_In_Any_Case;

   procedure A_Name_Spanning_Lines_Is_Not_A_Name (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Nested_Tagged ("multi abc" & LF & "def") = "", "not a single line");
   end A_Name_Spanning_Lines_Is_Not_A_Name;

   procedure A_Declaration_Inside_Another_Is_Found_Too
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Nested_Tagged ("outer Foo { inner Bar inner Baz }") =
         "Foo:function:def:0;Bar:function:def:0;Baz:function:def:0;",
         "the outer is named by its own identifier, and each inner by its");
   end A_Declaration_Inside_Another_Is_Found_Too;

   procedure Tags_Come_Out_In_Source_Order (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Nested_Tagged
           ("shallow [ [ a" & LF & "wrap var b" & LF & "upper C" & LF &
            "outer D { inner E }") =
         "a:function:def:0;b:function:def:1;C:function:def:2;" &
         "D:function:def:3;E:function:def:3;",
         "depth first, siblings left to right");
   end Tags_Come_Out_In_Source_Order;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Tree_Sitter.Tagger");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Predicates_Are_Classified_Into_Skip_Evaluate_And_Refuse'Access,
         "Predicates are classified into skip, evaluate and refuse");
      Register_Routine
        (T, Eq_Keeps_Only_The_Matching_Name'Access,
         "Eq and not-eq keep only the matching names");
      Register_Routine
        (T, Any_Of_Keeps_Only_The_Listed_Names'Access,
         "Any-of and not-any-of keep only the listed names");
      Register_Routine
        (T, Every_Predicate_Of_A_Pattern_Is_Evaluated'Access,
         "Every predicate of a pattern is evaluated");
      Register_Routine
        (T, A_Literal_Where_A_Capture_Is_Expected_Is_Refused_Or_Fails'Access,
         "A literal where a capture is expected is refused or fails");
      Register_Routine
        (T, A_Capture_Can_Be_Compared_With_Another_Capture'Access,
         "A capture can be compared with another capture");
      Register_Routine
        (T, A_Directive_Rewrites_And_Does_Not_Filter'Access,
         "A directive rewrites and does not filter");
      Register_Routine
        (T,
         A_Predicate_That_Cannot_Be_Evaluated_Disables_Only_Its_Pattern'Access,
         "A predicate that cannot be evaluated disables only its pattern");
      Register_Routine
        (T, A_Definition_Is_Tagged_With_Its_Line_And_Trimmed_Source'Access,
         "A definition is tagged with its line and trimmed source");
      Register_Routine
        (T, The_Echoed_Line_Is_The_Whole_Line_Trimmed'Access,
         "The echoed line is the whole line, trimmed");
      Register_Routine
        (T, A_Reference_Capture_Gives_A_Reference'Access,
         "A reference capture gives a reference");
      Register_Routine
        (T, A_Match_Without_A_Name_Or_Without_A_Role_Is_Not_A_Tag'Access,
         "A match without a name or without a role is not a tag");
      Register_Routine
        (T, An_Empty_File_Has_No_Tags_And_That_Is_A_Success'Access,
         "An empty file has no tags and that is a success");
      Register_Routine
        (T, A_Query_That_Does_Not_Compile_Is_Refused'Access,
         "A query that does not compile is refused");
      Register_Routine
        (T, A_Tagger_That_Was_Not_Created_Does_Not_Tag'Access,
         "A tagger that was not created does not tag");
      Register_Routine
        (T, A_Local_Definition_Is_Both_Name_And_Role'Access,
         "A local definition is both name and role");
      Register_Routine
        (T, A_Bare_Local_Definition_Is_Mapped_By_An_Empty_Spelling'Access,
         "A bare local definition is mapped by an empty spelling");
      Register_Routine
        (T, An_Unmapped_Or_Differently_Scoped_Kind_Is_Dropped'Access,
         "An unmapped or differently scoped kind is dropped");
      Register_Routine
        (T, A_Capture_That_Only_Starts_Like_A_Definition_Is_Not_One'Access,
         "A capture that only starts like a definition is not one");
      Register_Routine
        (T, A_Reference_That_Matches_A_Local_Definition_Is_Dropped'Access,
         "A reference that matches a local definition is dropped");
      Register_Routine
        (T, A_Reference_That_Matches_No_Local_Definition_Survives'Access,
         "A reference that matches no local definition survives");
      Register_Routine
        (T, A_Grammar_With_No_Locals_Keeps_Every_Reference'Access,
         "A grammar with no locals keeps every reference");
      Register_Routine
        (T, A_Locals_Query_That_Is_Unusable_Degrades_Without_Refusing'Access,
         "A locals query that is unusable degrades without refusing");
      Register_Routine
        (T, A_Definition_Is_Never_Dropped_As_A_Local_Reference'Access,
         "A definition is never dropped as a local reference");
      Register_Routine
        (T, The_Query_And_The_Walk_Combine_In_Every_Emptiness_Case'Access,
         "The query and the walk combine in every emptiness case");
      Register_Routine
        (T,
         The_Fixture_Is_Classified_As_Declarations_With_No_Name_Field'Access,
         "The nested fixture is classified, none with a name field");
      Register_Routine
        (T, Two_Guessed_Declarations_Around_One_Identifier_Are_One_Tag'Access,
         "Two guessed declarations around one identifier are one tag");
      Register_Routine
        (T, A_Name_Three_Levels_Down_Is_Found_And_Four_Is_Not'Access,
         "A name three levels down is found and four is not");
      Register_Routine
        (T, A_Node_Is_Never_Its_Own_Name'Access,
         "A node is never its own name");
      Register_Routine
        (T, A_Name_Type_Is_Matched_In_Any_Case'Access,
         "A name type is matched in any case");
      Register_Routine
        (T, A_Name_Spanning_Lines_Is_Not_A_Name'Access,
         "A name spanning lines is not a name");
      Register_Routine
        (T, A_Declaration_Inside_Another_Is_Found_Too'Access,
         "A declaration inside another is found too");
      Register_Routine
        (T, Tags_Come_Out_In_Source_Order'Access,
         "Tags come out in source order");
   end Register_Tests;

end Synapse.Adapters.Tree_Sitter.Tagger.Tests;
