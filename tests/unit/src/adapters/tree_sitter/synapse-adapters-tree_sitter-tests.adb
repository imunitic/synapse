with Ada.Characters.Latin_1;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with System;

with AUnit.Assertions;
with Synapse.Adapters.Dynamic_Libraries;
with Synapse.Adapters.Tree_Sitter.Grammar;
with Synapse.Core.Grammar_Names;
with Synapse.Ports.Library_Loader;

package body Synapse.Adapters.Tree_Sitter.Tests is

   use AUnit.Assertions;

   package Port renames Synapse.Ports.Library_Loader;

   use type Grammar.Load_Error;
   use type Port.Open_Status;
   use type System.Address;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Ada.Characters.Latin_1.LF;

   --  Byte offsets: line 0 is 0 .. 13, line 1 starts at 15, line 2 at 36.
   Source : constant String :=
     "// doc for foo" & LF & "fn foo() { return; }" & LF & "struct Bar { }" &
     LF;

   Real_Loader : Dynamic_Libraries.System_Loader;

   function Fixture_Path (Name : String) return String is
     ("fixtures/lib/lib" & Name & "." & Real_Loader.Extension);

   function Load (Name, Symbol : String) return Grammar.Load_Result is
     (Grammar.Load_Language (Real_Loader, Fixture_Path (Name), Symbol));

   --  The language of the docstrings fixture, or a failed assertion.
   function Docstrings_Language return Language is
      Result : constant Grammar.Load_Result :=
        Load ("fake_docstrings", "tree_sitter_fake_docstrings");
   begin
      Assert
        (Grammar.Load_Results.Is_Success (Result),
         "the docstrings fixture loads");
      return Grammar.Load_Results.Value (Result);
   end Docstrings_Language;

   function Text (N : Node; In_Source : String) return String is
     (In_Source
        (In_Source'First + Start_Byte (N) ..
             In_Source'First + End_Byte (N) - 1));

   ---------------------------------------------------------------------------
   --  Parsing and nodes
   ---------------------------------------------------------------------------

   procedure Parses_And_Walks_A_Tree (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      P  : Parser;
      OK : Boolean;
   begin
      Set_Language (P, Docstrings_Language, OK);
      Assert (OK, "the parser accepts the language");

      declare
         Parsed : constant Tree := Parse (P, Source);
         Root_N : constant Node := Root (Parsed);
      begin
         Assert (not Is_Null (Parsed), "parsing yields a tree");
         Assert (Kind (Root_N) = "source_file", "root kind");
         Assert (Start_Byte (Root_N) = 0, "root starts at byte 0");
         Assert (Named_Child_Count (Root_N) = 3, "comment, function, struct");

         declare
            Comment : constant Node := Named_Child (Root_N, 1);
            Fn      : constant Node := Named_Child (Root_N, 2);
            Struct  : constant Node := Named_Child (Root_N, 3);
         begin
            Assert (Kind (Comment) = "comment", "first child");
            Assert (Text (Comment, Source) = "// doc for foo", "comment text");
            Assert (Kind (Fn) = "function_declaration", "second child");
            Assert
              (Start_Byte (Fn) = 15 and then End_Byte (Fn) = 35,
               "function byte range");
            Assert
              (Start_Point (Fn) = (Row => 1, Column => 0),
               "function start point");
            Assert
              (End_Point (Fn) = (Row => 1, Column => 20),
               "function end point");
            Assert (Kind (Struct) = "struct_item", "third child");
            Assert (Text (Struct, Source) = "struct Bar { }", "struct text");

            Assert (Named_Child_Count (Fn) = 2, "identifier and return");
            Assert
              (Kind (Named_Child (Fn, 2)) = "return_statement",
               "return statement");
         end;
      end;
   end Parses_And_Walks_A_Tree;

   procedure Looks_Up_Children_By_Field (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      P  : Parser;
      OK : Boolean;
   begin
      Set_Language (P, Docstrings_Language, OK);
      declare
         Parsed : constant Tree := Parse (P, Source);
         Fn     : constant Node := Named_Child (Root (Parsed), 2);
         Name   : constant Node := Child_By_Field (Fn, "name");
      begin
         Assert (not Is_Null (Name), "the name field is present");
         Assert (Text (Name, Source) = "foo", "the name is foo");
         Assert
           (Is_Null (Child_By_Field (Fn, "no_such_field")),
            "an unknown field is null");
      end;
   end Looks_Up_Children_By_Field;

   procedure A_Parser_Without_A_Language_Yields_A_Null_Tree
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : Parser;
   begin
      Assert (Is_Null (Parse (P, Source)), "no language, no tree");
   end A_Parser_Without_A_Language_Yields_A_Null_Tree;

   procedure Handles_Empty_And_Repeated_Parses (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      P  : Parser;
      OK : Boolean;
   begin
      Set_Language (P, Docstrings_Language, OK);
      Assert (Named_Child_Count (Root (Parse (P, ""))) = 0, "empty source");
      for I in 1 .. 2_000 loop
         declare
            Parsed : constant Tree := Parse (P, Source);
         begin
            if Named_Child_Count (Root (Parsed)) /= 3 then
               Assert (False, "parse" & I'Image & " differs");
            end if;
         end;
      end loop;
   end Handles_Empty_And_Repeated_Parses;

   ---------------------------------------------------------------------------
   --  Queries
   ---------------------------------------------------------------------------

   Pattern_Source : constant String :=
     "(function_declaration name: (identifier) @fn.name)" & LF &
     "(struct_item name: (identifier) @struct.name" &
     " (#eq? @struct.name ""Bar""))";

   procedure Compiles_A_Query_And_Reads_Its_Matches
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Lang   : constant Language := Docstrings_Language;
      P      : Parser;
      OK     : Boolean;
      Q      : Query;
      Status : Query_Status;
      Offset : Natural;
   begin
      Set_Language (P, Lang, OK);
      Compile (Q, Lang, Pattern_Source, Status, Offset);
      Assert (Status = Compiled, "the query compiles");
      Assert (Is_Compiled (Q), "and is compiled");
      Assert (Pattern_Count (Q) = 2, "two patterns");

      declare
         Parsed : constant Tree := Parse (P, Source);
         C      : Cursor;
         Found  : Boolean;
         M      : Match;
      begin
         Exec (C, Q, Root (Parsed));

         Next_Match (C, Found, M);
         Assert (Found, "first match");
         Assert
           (Pattern (M) = 0 and then Capture_Count (M) = 1,
            "function pattern");
         Assert
           (Capture_Name (Q, Capture (M, 1).Id) = "fn.name", "capture name");
         Assert
           (Text (Capture (M, 1).Captured, Source) = "foo", "captured text");

         Next_Match (C, Found, M);
         Assert (Found, "second match");
         Assert
           (Pattern (M) = 1 and then Capture_Count (M) = 1, "struct pattern");
         Assert
           (Text (Capture (M, 1).Captured, Source) = "Bar",
            "captured struct name");

         Next_Match (C, Found, M);
         Assert (not Found, "no third match");
      end;
   end Compiles_A_Query_And_Reads_Its_Matches;

   procedure Exposes_Predicate_Steps (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Lang   : constant Language := Docstrings_Language;
      Q      : Query;
      Status : Query_Status;
      Offset : Natural;
   begin
      Compile (Q, Lang, Pattern_Source, Status, Offset);
      Assert (Status = Compiled, "the query compiles");
      Assert (Predicates (Q, 0)'Length = 0, "the first pattern has none");

      declare
         Steps : constant Predicate_Steps := Predicates (Q, 1);
      begin
         Assert (Steps'Length = 4, "eq?, capture, string, done");
         Assert
           (Steps (1).Kind = String_Literal
            and then String_Value (Q, Steps (1).Value) = "eq?",
            "the predicate name");
         Assert
           (Steps (2).Kind = Capture
            and then Capture_Name (Q, Steps (2).Value) = "struct.name",
            "the captured operand");
         Assert
           (Steps (3).Kind = String_Literal
            and then String_Value (Q, Steps (3).Value) = "Bar",
            "the literal operand");
         Assert (Steps (4).Kind = Done, "the terminator");
      end;
   end Exposes_Predicate_Steps;

   procedure Reports_Query_Errors (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Lang   : constant Language := Docstrings_Language;
      Q      : Query;
      Status : Query_Status;
      Offset : Natural;
   begin
      Compile (Q, Lang, "(function_declaration", Status, Offset);
      Assert (Status = Syntax_Error, "unbalanced parenthesis");
      Assert (not Is_Compiled (Q), "a failed query stays empty");

      Compile (Q, Lang, "(no_such_node)", Status, Offset);
      Assert (Status = Unknown_Node_Type, "unknown node type");

      Compile
        (Q, Lang, "(function_declaration no_such: (identifier))", Status,
         Offset);
      Assert (Status = Unknown_Field, "unknown field");

      Compile (Q, Lang, "(identifier) (#eq? @missing ""a"")", Status, Offset);
      Assert (Status = Unknown_Capture, "undefined capture in a predicate");
   end Reports_Query_Errors;

   procedure Disabled_Patterns_Stop_Matching (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Lang   : constant Language := Docstrings_Language;
      P      : Parser;
      OK     : Boolean;
      Q      : Query;
      Status : Query_Status;
      Offset : Natural;
   begin
      Set_Language (P, Lang, OK);
      Compile (Q, Lang, Pattern_Source, Status, Offset);
      Disable_Pattern (Q, 0);
      declare
         Parsed : constant Tree := Parse (P, Source);
         C      : Cursor;
         Found  : Boolean;
         M      : Match;
      begin
         Exec (C, Q, Root (Parsed));
         Next_Match (C, Found, M);
         Assert (Found and then Pattern (M) = 1, "only the struct pattern");
         Next_Match (C, Found, M);
         Assert (not Found, "nothing else");
      end;
   end Disabled_Patterns_Stop_Matching;

   ---------------------------------------------------------------------------
   --  Grammar loading
   ---------------------------------------------------------------------------

   procedure Loads_Grammars_Of_Supported_Abis (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Newer : constant Grammar.Load_Result :=
        Load ("fake_docstrings", "tree_sitter_fake_docstrings");
      Older : constant Grammar.Load_Result :=
        Load ("fake3", "tree_sitter_fake3");
   begin
      Assert
        (Grammar.Load_Results.Is_Success (Newer)
         and then ABI_Version (Grammar.Load_Results.Value (Newer)) = 15,
         "ABI 15");
      Assert
        (Grammar.Load_Results.Is_Success (Older)
         and then ABI_Version (Grammar.Load_Results.Value (Older)) = 14,
         "ABI 14");
   end Loads_Grammars_Of_Supported_Abis;

   procedure Refuses_An_Unsupported_Abi (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Grammar.Load_Result :=
        Load ("fake_abi16", "tree_sitter_fake_abi16");
   begin
      Assert
        (not Grammar.Load_Results.Is_Success (Result)
         and then Grammar.Load_Results.Error (Result) =
           Grammar.Abi_Unsupported,
         "ABI 16 is newer than the runtime");
   end Refuses_An_Unsupported_Abi;

   procedure Reports_Load_Failures (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Missing : constant Grammar.Load_Result :=
        Grammar.Load_Language (Real_Loader, "fixtures/lib/no_such_lib", "x");
      Not_Lib : constant Grammar.Load_Result :=
        Grammar.Load_Language (Real_Loader, "fixtures/fixtures.gpr", "x");
      No_Sym  : constant Grammar.Load_Result :=
        Load ("fake3", "tree_sitter_no_such_symbol");
   begin
      Assert
        (not Grammar.Load_Results.Is_Success (Missing)
         and then Grammar.Load_Results.Error (Missing) =
           Grammar.Library_Not_Found,
         "a missing file");
      Assert
        (not Grammar.Load_Results.Is_Success (Not_Lib)
         and then Grammar.Load_Results.Error (Not_Lib) = Grammar.Not_A_Library,
         "a file that is not a library");
      Assert
        (not Grammar.Load_Results.Is_Success (No_Sym)
         and then Grammar.Load_Results.Error (No_Sym) =
           Grammar.Symbol_Not_Found,
         "a missing symbol");
   end Reports_Load_Failures;

   --  A loader that never touches the operating system.
   type Canned_Loader is new Port.Loader with record
      Open_Status  : Port.Open_Status := Port.Opened;
      Symbol_At    : System.Address   := System.Null_Address;
      Open_Calls   : Natural          := 0;
      Symbol_Calls : Natural          := 0;
   end record;

   overriding procedure Open
     (L      : in out Canned_Loader; Path : String; Lib : out Port.Library;
      Status :    out Port.Open_Status);

   overriding function Symbol
     (L : Canned_Loader; Lib : Port.Library; Name : String)
      return System.Address;

   overriding function Extension (L : Canned_Loader) return String;

   overriding procedure Open
     (L      : in out Canned_Loader; Path : String; Lib : out Port.Library;
      Status :    out Port.Open_Status)
   is
      pragma Unreferenced (Path);
   begin
      L.Open_Calls := L.Open_Calls + 1;
      Lib          := Port.No_Library;
      Status       := L.Open_Status;
   end Open;

   overriding function Symbol
     (L : Canned_Loader; Lib : Port.Library; Name : String)
      return System.Address
   is
      pragma Unreferenced (Lib, Name);
   begin
      return L.Symbol_At;
   end Symbol;

   overriding function Extension (L : Canned_Loader) return String is ("fake");

   function Null_Language return Thin.Language_Ptr with
     Convention => C;

   function Null_Language return Thin.Language_Ptr is (Thin.Null_Language);

   procedure Load_Language_Depends_Only_On_The_Port
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Loader : Canned_Loader;
   begin
      Loader.Open_Status := Port.Not_Found;
      declare
         R : constant Grammar.Load_Result :=
           Grammar.Load_Language (Loader, "anything", "tree_sitter_x");
      begin
         Assert
           (not Grammar.Load_Results.Is_Success (R)
            and then Grammar.Load_Results.Error (R) =
              Grammar.Library_Not_Found,
            "Open's status is passed through");
         Assert (Loader.Open_Calls = 1, "the port was asked to open");
      end;

      Loader.Open_Status := Port.Opened;
      declare
         R : constant Grammar.Load_Result :=
           Grammar.Load_Language (Loader, "anything", "tree_sitter_x");
      begin
         Assert
           (not Grammar.Load_Results.Is_Success (R)
            and then Grammar.Load_Results.Error (R) = Grammar.Symbol_Not_Found,
            "an unresolved symbol");
      end;

      Loader.Symbol_At := Null_Language'Address;
      declare
         R : constant Grammar.Load_Result :=
           Grammar.Load_Language (Loader, "anything", "tree_sitter_x");
      begin
         Assert
           (not Grammar.Load_Results.Is_Success (R)
            and then Grammar.Load_Results.Error (R) = Grammar.Symbol_Not_Found,
            "a grammar function returning no language");
      end;
   end Load_Language_Depends_Only_On_The_Port;

   procedure The_Loader_Reports_A_Known_Extension (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Ext : constant String := Real_Loader.Extension;
   begin
      Assert (Ext in "so" | "dylib" | "dll", "extension is " & Ext);
   end The_Loader_Reports_A_Known_Extension;

   --  The runtime's accepted ABI range is written in the Ada wrapper; the
   --  header it was vendored with is the source of truth.
   procedure Abi_Constants_Match_The_Vendored_Header
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Header : constant String :=
        "../../vendor/tree-sitter/lib/include/tree_sitter/api.h";
      File   : Ada.Text_IO.File_Type;
      Newest : Integer         := -1;
      Oldest : Integer         := -1;

      function Value_After (Line, Name : String) return Integer is
         At_Name : constant Natural := Ada.Strings.Fixed.Index (Line, Name);
      begin
         if At_Name = 0 then
            return -1;
         end if;
         return
           Integer'Value
             (Ada.Strings.Fixed.Trim
                (Line (At_Name + Name'Length .. Line'Last), Ada.Strings.Both));
      end Value_After;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Header);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            if Line'Length > 8
              and then Line (Line'First .. Line'First + 7) = "#define "
            then
               if Ada.Strings.Fixed.Index
                   (Line, "TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION") >
                 0
               then
                  Oldest :=
                    Value_After
                      (Line, "TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION");
               elsif Ada.Strings.Fixed.Index
                   (Line, "TREE_SITTER_LANGUAGE_VERSION") >
                 0
               then
                  Newest := Value_After (Line, "TREE_SITTER_LANGUAGE_VERSION");
               end if;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);

      Assert (Newest = ABI_Max, "ABI_Max is" & Newest'Image & " in api.h");
      Assert (Oldest = ABI_Min, "ABI_Min is" & Oldest'Image & " in api.h");
   end Abi_Constants_Match_The_Vendored_Header;

   procedure Derives_Entry_Point_Names (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      use Synapse.Core.Grammar_Names;
   begin
      Assert (Symbol_For ("tree-sitter-java") = "tree_sitter_java", "plain");
      Assert
        (Symbol_For ("tree-sitter-c-sharp") = "tree_sitter_c_sharp",
         "dashes become underscores");
      Assert
        (Symbol_For ("foo-bar") = "tree_sitter_foo_bar",
         "a name without the repository prefix");
      Assert (Symbol_For ("tree-sitter-") = "tree_sitter_", "empty stem");
      Assert (Symbol_For ("") = "tree_sitter_", "empty name");
   end Derives_Entry_Point_Names;

   ---------------------------------------------------------------------------

   procedure Reads_The_Text_Of_A_Node_Within_The_Parsed_Source
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P  : Parser;
      OK : Boolean;
   begin
      Set_Language (P, Docstrings_Language, OK);
      declare
         Parsed : constant Tree := Parse (P, Source);
         First  : constant Node := Named_Child (Root (Parsed), 2);
      begin
         Assert (Lies_Within (First, Source), "within the text it came from");
         Assert (Text_Of (First, Source) = "fn foo() { return; }", "its text");
         Assert
           (not Lies_Within (First, "short"),
            "not within a text that is too short");
         Assert (Lies_Within (First, "x" & Source), "any text long enough");
      end;
   end Reads_The_Text_Of_A_Node_Within_The_Parsed_Source;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Tree_Sitter");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Reads_The_Text_Of_A_Node_Within_The_Parsed_Source'Access,
         "Reads the text of a node within the parsed source");
      Register_Routine
        (T, Parses_And_Walks_A_Tree'Access, "Parses and walks a tree");
      Register_Routine
        (T, Looks_Up_Children_By_Field'Access, "Looks up children by field");
      Register_Routine
        (T, A_Parser_Without_A_Language_Yields_A_Null_Tree'Access,
         "A parser without a language yields a null tree");
      Register_Routine
        (T, Handles_Empty_And_Repeated_Parses'Access,
         "Handles empty and repeated parses");
      Register_Routine
        (T, Compiles_A_Query_And_Reads_Its_Matches'Access,
         "Compiles a query and reads its matches");
      Register_Routine
        (T, Exposes_Predicate_Steps'Access, "Exposes predicate steps");
      Register_Routine
        (T, Reports_Query_Errors'Access, "Reports query errors");
      Register_Routine
        (T, Disabled_Patterns_Stop_Matching'Access,
         "Disabled patterns stop matching");
      Register_Routine
        (T, Loads_Grammars_Of_Supported_Abis'Access,
         "Loads grammars of supported ABIs");
      Register_Routine
        (T, Refuses_An_Unsupported_Abi'Access, "Refuses an unsupported ABI");
      Register_Routine
        (T, Reports_Load_Failures'Access, "Reports load failures");
      Register_Routine
        (T, Load_Language_Depends_Only_On_The_Port'Access,
         "Load_Language depends only on the port");
      Register_Routine
        (T, The_Loader_Reports_A_Known_Extension'Access,
         "The loader reports a known extension");
      Register_Routine
        (T, Abi_Constants_Match_The_Vendored_Header'Access,
         "ABI constants match the vendored header");
      Register_Routine
        (T, Derives_Entry_Point_Names'Access, "Derives entry point names");
   end Register_Tests;

end Synapse.Adapters.Tree_Sitter.Tests;
