with Ada.Containers;

with AUnit.Assertions;

with Synapse.Adapters.Dynamic_Libraries;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Tree_Sitter.Grammar;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Tree_Sitter.Docstring_Pairs.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Real_Loader : Dynamic_Libraries.System_Loader;

   No_Extra : Core.Text_Lists.Vector;

   function Docstrings return Language is
      Loaded : constant Grammar.Load_Result :=
        Grammar.Load_Language
          (Real_Loader,
           "fixtures/lib/libfake_docstrings." & Real_Loader.Extension,
           "tree_sitter_fake_docstrings");
   begin
      Assert (Loaded.Loaded, "the docstrings fixture loads");
      return Loaded.Item;
   end Docstrings;

   function Pairs_In
     (Source : String; Comment_Type : String := "comment";
      Extra  : Core.Text_Lists.Vector := No_Extra) return Pair_Vectors.Vector
   is
      Got : constant Pair_Results.Result :=
        Find_Pairs (Docstrings, Source, Comment_Type, Extra);
   begin
      Assert (Pair_Results.Is_Success (Got), "the file parses");
      return Pair_Results.Value (Got);
   end Pairs_In;

   function Text_Of (P : Pair; Field : String) return String is
     (if Field = "kind" then To_String (P.Kind)
      elsif Field = "name" then To_String (P.Name)
      elsif Field = "docstring" then To_String (P.Docstring_Text)
      else To_String (P.Decl_Text));

   procedure A_Single_Line_Comment_Above_A_Declaration_Pairs_With_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Pair_Vectors.Vector :=
        Pairs_In ("// does a thing" & LF & "fn foo()" & LF);
   begin
      Assert (Natural (Got.Length) = 1, "one pair");
      Assert (Text_Of (Got (1), "kind") = "function_declaration", "kind");
      Assert (Text_Of (Got (1), "name") = "fn foo()", "its first line");
      Assert (Text_Of (Got (1), "docstring") = "// does a thing", "docstring");
      Assert (Text_Of (Got (1), "decl") = "fn foo()", "declaration text");
      Assert
        (Got (1).Docstring_Start_Line = 1
         and then Got (1).Docstring_End_Line = 1
         and then Got (1).Decl_Start_Line = 2
         and then Got (1).Decl_End_Line = 2,
         "1-based lines");
   end A_Single_Line_Comment_Above_A_Declaration_Pairs_With_It;

   procedure A_Stacked_Run_Pairs_As_One_Docstring_Joined_By_Line_Feed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Pair_Vectors.Vector :=
        Pairs_In ("// line one" & LF & "// line two" & LF & "fn foo()" & LF);
   begin
      Assert (Natural (Got.Length) = 1, "one pair");
      Assert
        (Text_Of (Got (1), "docstring") = "// line one" & LF & "// line two",
         "joined");
      Assert
        (Got (1).Docstring_Start_Line = 1
         and then Got (1).Docstring_End_Line = 2
         and then Got (1).Decl_Start_Line = 3
         and then Got (1).Decl_End_Line = 3,
         "the run's lines");
   end A_Stacked_Run_Pairs_As_One_Docstring_Joined_By_Line_Feed;

   procedure A_Blank_Line_Before_The_Declaration_Means_No_Pairing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Pairs_In ("// floating comment" & LF & LF & "fn foo()" & LF).Is_Empty,
         "a floating comment");
      Assert
        (Pairs_In ("// a" & LF & LF & "// b" & LF & "fn foo()" & LF).Length =
         1,
         "a blank line ends a run: only the second pairs");
   end A_Blank_Line_Before_The_Declaration_Means_No_Pairing;

   procedure A_Declaration_With_No_Comment_Is_Not_Paired
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Pairs_In ("fn foo()" & LF).Is_Empty, "nothing above it");
      Assert
        (Pairs_In ("// last line").Is_Empty, "a comment with nothing below");
      Assert (Pairs_In ("").Is_Empty, "an empty file");
   end A_Declaration_With_No_Comment_Is_Not_Paired;

   procedure Two_Declarations_Each_Get_Their_Own_Comment
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Pair_Vectors.Vector :=
        Pairs_In
          ("// first" & LF & "fn foo()" & LF & "// second" & LF &
           "struct Bar {}" & LF);
   begin
      Assert (Natural (Got.Length) = 2, "two pairs");
      Assert
        (Text_Of (Got (1), "docstring") = "// first"
         and then Text_Of (Got (1), "kind") = "function_declaration",
         "the first");
      Assert
        (Text_Of (Got (2), "docstring") = "// second"
         and then Text_Of (Got (2), "kind") = "struct_item",
         "the second");
   end Two_Declarations_Each_Get_Their_Own_Comment;

   procedure A_Comment_Above_A_Statement_In_A_Body_Is_Not_Paired
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Pairs_In
           ("fn foo() {" & LF & "// a note about returning" & LF & "return;" &
            LF & "}" & LF)
           .Is_Empty,
         "a statement has no name field");
   end A_Comment_Above_A_Statement_In_A_Body_Is_Not_Paired;

   procedure A_Declaration_Override_Brings_Back_A_Kind_Without_A_Name_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Extra : Core.Text_Lists.Vector;
   begin
      Extra.Append
        (Ada.Strings.Unbounded.To_Unbounded_String ("return_statement"));
      declare
         Got : constant Pair_Vectors.Vector :=
           Pairs_In
             ("fn foo() {" & LF & "// a note about returning" & LF &
              "return;" & LF & "}" & LF,
              Extra => Extra);
      begin
         Assert (Natural (Got.Length) = 1, "paired");
         Assert
           (Text_Of (Got (1), "kind") = "return_statement", "the node type");
         Assert
           (Text_Of (Got (1), "docstring") = "// a note about returning",
            "its docstring");
         Assert
           (Got (1).Docstring_Start_Line = 2
            and then Got (1).Decl_Start_Line = 3,
            "nested lines are the file's");
      end;
   end A_Declaration_Override_Brings_Back_A_Kind_Without_A_Name_Field;

   procedure Pairs_In_Sibling_Subtrees_Come_Out_In_Source_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Extra : Core.Text_Lists.Vector;
   begin
      Extra.Append
        (Ada.Strings.Unbounded.To_Unbounded_String ("return_statement"));
      declare
         Got : constant Pair_Vectors.Vector :=
           Pairs_In
             ("// top" & LF & "fn foo() {" & LF & "// first note" & LF &
              "return;" & LF & "}" & LF & "fn bar() {" & LF &
              "// second note" & LF & "return;" & LF & "}" & LF,
              Extra => Extra);
      begin
         Assert (Natural (Got.Length) = 2 + 1, "a pair above and one in each");
         Assert
           (Text_Of (Got (1), "docstring") = "// top",
            "a node's own pair before those below it");
         Assert
           (Text_Of (Got (2), "docstring") = "// first note"
            and then Text_Of (Got (3), "docstring") = "// second note",
            "then the subtrees left to right");
      end;
   end Pairs_In_Sibling_Subtrees_Come_Out_In_Source_Order;

   procedure An_Overridden_Comment_Type_Is_Honoured
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Pairs_In
           ("// does a thing" & LF & "fn foo()" & LF,
            Comment_Type => "not_a_real_comment_type")
           .Is_Empty,
         "a type this grammar has not: nothing is a comment");
   end An_Overridden_Comment_Type_Is_Honoured;

   procedure A_Multi_Line_Declaration_Is_Named_By_Its_First_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Pair_Vectors.Vector :=
        Pairs_In
          ("// doc" & LF & "fn foo() {" & LF & "return;" & LF & "}" & LF);
   begin
      Assert (Natural (Got.Length) = 1, "one pair");
      Assert (Text_Of (Got (1), "name") = "fn foo() {", "the first line");
      Assert
        (Text_Of (Got (1), "decl") = "fn foo() {" & LF & "return;" & LF & "}",
         "the whole text");
      Assert
        (Got (1).Decl_Start_Line = 2 and then Got (1).Decl_End_Line = 4,
         "its lines");
   end A_Multi_Line_Declaration_Is_Named_By_Its_First_Line;

   ---------------------------------------------------------------------------
   --  The override files
   ---------------------------------------------------------------------------

   function Dir_Of (S : Scratch) return Core.Grammar_Registry.Maybe_Text is
     (Present => True,
      Text    => Ada.Strings.Unbounded.To_Unbounded_String (Path (S)));

   procedure The_Comment_Type_Is_The_Default_Unless_A_File_Names_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Assert
        (Comment_Type_Name ((Present => False), "ext") = "comment",
         "no override directory");
      Assert
        (Comment_Type_Name (Dir_Of (Dir), "ext") = "comment",
         "an absent file");
      File_Bytes.Write
        (Path (Dir, "ext.comments.scm"), "(line_comment) @comment" & LF);
      Assert
        (Comment_Type_Name (Dir_Of (Dir), "ext") = "line_comment",
         "a file's node type wins");
      Assert
        (Comment_Type_Name (Dir_Of (Dir), "other") = "comment",
         "another extension is unaffected");
      File_Bytes.Write (Path (Dir, "empty.comments.scm"), "; nothing");
      Assert
        (Comment_Type_Name (Dir_Of (Dir), "empty") = "comment",
         "a file that names none");
      File_Bytes.Write
        (Path (Dir, "long.comments.scm"), "(big) " & [1 .. 5_000 => ' ']);
      Assert
        (Comment_Type_Name (Dir_Of (Dir), "long") = "comment",
         "one longer than 4,096 bytes names none");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Comment_Type_Is_The_Default_Unless_A_File_Names_One;

   procedure Declaration_Overrides_Are_Read_One_Per_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Assert
        (Declaration_Overrides ((Present => False), "ext").Is_Empty,
         "no override directory");
      Assert
        (Declaration_Overrides (Dir_Of (Dir), "ext").Is_Empty,
         "an absent file is none and not an error");
      File_Bytes.Write
        (Path (Dir, "ext.declarations.scm"),
         "(variable_declaration) @declaration" & LF & LF &
         "(return_statement)" & LF);
      declare
         Got : constant Core.Text_Lists.Vector :=
           Declaration_Overrides (Dir_Of (Dir), "ext");
      begin
         Assert (Natural (Got.Length) = 2, "two");
         Assert
           (Ada.Strings.Unbounded.To_String (Got (1)) = "variable_declaration"
            and then Ada.Strings.Unbounded.To_String (Got (2)) =
              "return_statement",
            "in order");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Declaration_Overrides_Are_Read_One_Per_Line;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Tree_Sitter.Docstring_Pairs");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Single_Line_Comment_Above_A_Declaration_Pairs_With_It'Access,
         "A single line comment above a declaration pairs with it");
      Register_Routine
        (T, A_Stacked_Run_Pairs_As_One_Docstring_Joined_By_Line_Feed'Access,
         "A stacked run pairs as one docstring, joined by line feeds");
      Register_Routine
        (T, A_Blank_Line_Before_The_Declaration_Means_No_Pairing'Access,
         "A blank line before the declaration means no pairing");
      Register_Routine
        (T, A_Declaration_With_No_Comment_Is_Not_Paired'Access,
         "A declaration with no comment is not paired");
      Register_Routine
        (T, Two_Declarations_Each_Get_Their_Own_Comment'Access,
         "Two declarations each get their own comment");
      Register_Routine
        (T, A_Comment_Above_A_Statement_In_A_Body_Is_Not_Paired'Access,
         "A comment above a statement in a body is not paired");
      Register_Routine
        (T,
         A_Declaration_Override_Brings_Back_A_Kind_Without_A_Name_Field'Access,
         "A declaration override brings back a kind with no name field");
      Register_Routine
        (T, Pairs_In_Sibling_Subtrees_Come_Out_In_Source_Order'Access,
         "Pairs in sibling subtrees come out in source order");
      Register_Routine
        (T, An_Overridden_Comment_Type_Is_Honoured'Access,
         "An overridden comment type is honoured");
      Register_Routine
        (T, A_Multi_Line_Declaration_Is_Named_By_Its_First_Line'Access,
         "A multi-line declaration is named by its first line");
      Register_Routine
        (T, The_Comment_Type_Is_The_Default_Unless_A_File_Names_One'Access,
         "The comment type is the default unless a file names one");
      Register_Routine
        (T, Declaration_Overrides_Are_Read_One_Per_Line'Access,
         "Declaration overrides are read one per line");
   end Register_Tests;

end Synapse.Adapters.Tree_Sitter.Docstring_Pairs.Tests;
