with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Interfaces;

with AUnit.Assertions;

with Synapse.Core.JSON;

package body Synapse.Pipeline.Parser.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_32;
   use type Syntax.Definition_Kind;
   use type Syntax.Value_Kind;
   use type Synapse.Core.JSON.Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Empty_Pipeline : constant Syntax.Definition :=
     (Kind => Syntax.Pipeline_Definition, others => <>);

   --  The definition Source holds, which must parse.
   function Parse_OK (Source : String) return Syntax.Definition is
      R : constant Parse_Results.Result := Parse_Source (Source);
   begin
      Assert
        (Parse_Results.Is_Success (R),
         "parses: "
         & (if Parse_Results.Is_Success (R) then ""
            else Source_Errors.Image (Parse_Results.Error (R))));
      return Parse_Results.Value_Or (R, Empty_Pipeline);
   end Parse_OK;

   --  Source must fail with Message in its text, at Line and Column.
   procedure Assert_Fails
     (Source : String; Line, Column : Positive; Message : String;
      Label  : String)
   is
      R : constant Parse_Results.Result := Parse_Source (Source);
   begin
      Assert (not Parse_Results.Is_Success (R), Label & ": fails");
      if not Parse_Results.Is_Success (R) then
         declare
            E : constant Source_Errors.Source_Error := Parse_Results.Error (R);
         begin
            Assert
              (E.Line = Line and then E.Column = Column,
               Label & ": at " & Source_Errors.Image (E));
            Assert
              (Ada.Strings.Fixed.Index (To_String (E.Message), Message) > 0,
               Label & ": says '" & Message & "', says "
               & Source_Errors.Image (E));
         end;
      end if;
   end Assert_Fails;

   function Name_Of (R : Syntax.Reference) return String is
     (To_String (R.Name));

   procedure A_Pipeline_Parses_To_Its_Steps_And_Edges_In_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      D : constant Syntax.Definition :=
        Parse_OK
          ("Pipeline Develop_Feature {" & LF
           & "   Develop [Agent => Developer, Harness => Claude, Prompt => "
           & """Implement the checklist."", Retries => 2];" & LF
           & "   Test    [Agent => Tester, Skill => ""test-feature""];" & LF
           & "   Review  [System => Strict_Reviewer, Harness => Codex];" & LF
           & "   Review -> Develop [When => Changes_Requested,"
           & " Max_Iterations => 5];" & LF
           & "}" & LF);
   begin
      Assert (D.Kind = Syntax.Pipeline_Definition, "a pipeline");
      Assert
        (Name_Of (D.Name) = "Develop_Feature" and then D.Name.Line = 1
         and then D.Name.Column = 10,
         "its name, at 1:10");
      Assert (Natural (D.Steps.Length) = 3, "three steps");
      Assert
        (Name_Of (D.Steps (1).Name) = "Develop"
         and then Name_Of (D.Steps (2).Name) = "Test"
         and then Name_Of (D.Steps (3).Name) = "Review",
         "in the order written");
      Assert
        (D.Steps (1).Name.Line = 2 and then D.Steps (1).Name.Column = 4,
         "Develop at 2:4");

      declare
         A : constant Syntax.Attribute_Vectors.Vector :=
           D.Steps (1).Attributes;
      begin
         Assert (Natural (A.Length) = 4, "four attributes on Develop");
         Assert
           (Name_Of (A (1).Name) = "Agent" and then A (1).Name.Column = 13
            and then A (1).Item.Kind = Syntax.Name_Value
            and then To_String (A (1).Item.Name) = "Developer",
            "Agent => Developer, the attribute at 2:13");
         Assert
           (A (3).Item.Kind = Syntax.String_Value
            and then To_String (A (3).Item.Text) = "Implement the checklist.",
            "a string value");
         Assert
           (A (4).Item.Kind = Syntax.Integer_Value
            and then A (4).Item.Number = 2,
            "an integer value");
      end;

      Assert (Natural (D.Edges.Length) = 1, "one edge");
      Assert
        (Name_Of (D.Edges (1).From) = "Review"
         and then Name_Of (D.Edges (1).To) = "Develop"
         and then D.Edges (1).From.Line = 5,
         "Review to Develop, on line 5");
      Assert
        (Natural (D.Edges (1).Attributes.Length) = 2
         and then D.Edges (1).Attributes (2).Item.Number = 5,
         "its attributes");
   end A_Pipeline_Parses_To_Its_Steps_And_Edges_In_Order;

   procedure Systems_And_Agents_Hold_Attributes (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : constant Syntax.Definition :=
        Parse_OK
          ("System Strict_Reviewer [Agent => Reviewer, "
           & "Permissions => Read_Only];");
      A : constant Syntax.Definition :=
        Parse_OK
          ("Agent Reviewer [Prompt => """"""Review for" & LF
           & "correctness."""""", Scope => Repo];");
   begin
      Assert
        (S.Kind = Syntax.System_Definition
         and then Name_Of (S.Name) = "Strict_Reviewer"
         and then Natural (S.Attributes.Length) = 2,
         "a system with two attributes");
      Assert
        (A.Kind = Syntax.Agent_Definition
         and then Name_Of (A.Name) = "Reviewer",
         "an agent");
      Assert
        (To_String (A.Attributes (1).Item.Text) =
         "Review for" & LF & "correctness.",
         "a triple-quoted prompt, with its line break");
   end Systems_And_Agents_Hold_Attributes;

   procedure JSON_Values_Keep_Their_Structure (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      D : constant Syntax.Definition :=
        Parse_OK
          ("System S [When => {"">"": [{""var"": ""data.n""}, 0]}, "
           & "Tools => [""Read"", ""Grep""]];");
   begin
      Assert
        (D.Attributes (1).Item.Kind = Syntax.JSON_Value
         and then JSON.Kind_Of (D.Attributes (1).Item.Json) = JSON.JSON_Object,
         "an object");
      Assert
        (JSON.Kind_Of (D.Attributes (2).Item.Json) = JSON.JSON_Array
         and then JSON.Length (D.Attributes (2).Item.Json) = 2,
         "an array of two");
   end JSON_Values_Keep_Their_Structure;

   procedure A_Chain_Is_One_Edge_Per_Pair (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      D : constant Syntax.Definition :=
        Parse_OK
          ("Pipeline P { A -> B -> C [When => Done]; C -> A; }");
   begin
      Assert (Natural (D.Edges.Length) = 3, "A-B, B-C and C-A");
      Assert
        (Name_Of (D.Edges (1).From) = "A"
         and then Name_Of (D.Edges (1).To) = "B"
         and then Name_Of (D.Edges (2).From) = "B"
         and then Name_Of (D.Edges (2).To) = "C",
         "the chain, pair by pair");
      Assert
        (Natural (D.Edges (1).Attributes.Length) = 1
         and then Natural (D.Edges (2).Attributes.Length) = 1,
         "each with the chain's attributes");
      Assert (D.Edges (3).Attributes.Is_Empty, "an edge needs no attributes");
      Assert (D.Steps.Is_Empty, "and declares no step");
   end A_Chain_Is_One_Edge_Per_Pair;

   procedure Layout_Comments_And_Empty_Lists_Are_Fine
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      D : constant Syntax.Definition :=
        Parse_OK
          ("-- a pipeline" & LF & LF & "Pipeline P {  -- opens" & LF
           & "  A [];" & LF & "  B [ ] ;" & LF & "}" & LF & "-- done");
   begin
      Assert (Natural (D.Steps.Length) = 2, "two steps");
      Assert
        (D.Steps (1).Attributes.Is_Empty
         and then D.Steps (2).Attributes.Is_Empty,
         "with no attributes");
      Assert
        (Parse_OK ("System S [];").Attributes.Is_Empty, "an empty system");
      Assert
        (Parse_OK ("Pipeline P {}").Steps.Is_Empty, "an empty pipeline");
   end Layout_Comments_And_Empty_Lists_Are_Fine;

   procedure Keywords_May_Name_Attributes_But_Not_Steps
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      D : constant Syntax.Definition :=
        Parse_OK
          ("Pipeline P { A [System => X, Agent => Y, Pipeline => Z]; }");
   begin
      Assert
        (Natural (D.Steps (1).Attributes.Length) = 3
         and then Name_Of (D.Steps (1).Attributes (1).Name) = "System",
         "the three keywords as attribute names");
      Assert_Fails
        ("Pipeline P { Agent [] ; }", 1, 14, "keyword", "a step named Agent");
      Assert_Fails
        ("Pipeline System {}", 1, 10, "keyword", "a pipeline named System");
      Assert_Fails
        ("Pipeline P { A -> System; }", 1, 19, "keyword",
         "an edge to a keyword");
   end Keywords_May_Name_Attributes_But_Not_Steps;

   procedure Errors_Name_The_Line_And_Column (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert_Fails
        ("", 1, 1,
         "expected Pipeline, System or Agent, found the end of the file",
         "an empty file");
      Assert_Fails
        ("Frobnicate X [];", 1, 1,
         "expected Pipeline, System or Agent, found 'Frobnicate'",
         "an unknown kind");
      Assert_Fails
        ("Pipeline {", 1, 10, "expected the name of the Pipeline, found '{'",
         "a pipeline without a name");
      Assert_Fails
        ("Pipeline P {" & LF & "  A [];", 2, 8,
         "expected '}' to close the pipeline", "a pipeline left open");
      Assert_Fails
        ("Pipeline P { A [] B [] }", 1, 19, "expected ';', found 'B'",
         "a step without its semicolon");
      Assert_Fails
        ("Pipeline P { A; }", 1, 15,
         "expected '[' or '->' after the step name 'A', found ';'",
         "a step without brackets");
      Assert_Fails
        ("Pipeline P { A -> ; }", 1, 19,
         "expected a step name after '->', found ';'",
         "an edge without a target");
      Assert_Fails
        ("System S [A => ];", 1, 16,
         "expected a value after '=>', found ']'",
         "an attribute without a value");
      Assert_Fails
        ("System S [A B];", 1, 13, "expected '=>', found 'B'",
         "an attribute without an arrow");
      Assert_Fails
        ("System S [A => b, ];", 1, 19,
         "expected an attribute name, found ']'", "a trailing comma");
      Assert_Fails
        ("System S [A => b C => d];", 1, 18, "expected ',' or ']', found 'C'",
         "a missing comma");
      Assert_Fails
        ("System S []", 1, 12, "expected ';', found the end of the file",
         "a system without its semicolon");
      Assert_Fails
        ("System S [];" & LF & "Agent A [];", 2, 1,
         "a file holds one definition", "two definitions");
      Assert_Fails
        ("System S [A => ""oops];", 1, 16, "unterminated string",
         "a lexical error is passed through");
   end Errors_Name_The_Line_And_Column;

   procedure Random_Source_Never_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Piece_Count : constant := 17;

      function Piece (N : Positive) return String is
        (case N is
           when 1      => "Pipeline",
           when 2      => "System",
           when 3      => "Agent",
           when 4      => "A",
           when 5      => "Bee_2",
           when 6      => "{",
           when 7      => "}",
           when 8      => "[",
           when 9      => "]",
           when 10     => "=>",
           when 11     => "->",
           when 12     => ",",
           when 13     => ";",
           when 14     => """s""",
           when 15     => "12",
           when 16     => "{""k"": [1]}",
           when others => "--c" & LF);

      Seed   : Interfaces.Unsigned_32 := 777;

      function Next (Limit : Positive) return Positive is
      begin
         Seed := Seed * 1664525 + 1013904223;
         return Natural (Seed / 65536) mod Limit + 1;
      end Next;
   begin
      for Round in 1 .. 6000 loop
         declare
            Source : Unbounded_String;
         begin
            for I in 1 .. Next (24) loop
               Append (Source, Piece (Next (Piece_Count)) & " ");
            end loop;
            declare
               Text : constant String := To_String (Source);
               R    : constant Parse_Results.Result := Parse_Source (Text);
            begin
               if Parse_Results.Is_Success (R) then
                  Assert
                    (Length (Parse_Results.Value (R).Name.Name) > 0,
                     "a name: round" & Round'Image);
               else
                  Assert
                    (Parse_Results.Error (R).Line
                     <= Ada.Strings.Fixed.Count (Text, "" & LF) + 1,
                     "a line inside the source: round" & Round'Image);
               end if;
            end;
         exception
            when others =>
               Assert (False, "raised on round" & Round'Image);
         end;
      end loop;
   end Random_Source_Never_Raises;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Parser");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Pipeline_Parses_To_Its_Steps_And_Edges_In_Order'Access,
         "A pipeline parses to its steps and edges in order");
      Register_Routine
        (T, Systems_And_Agents_Hold_Attributes'Access,
         "Systems and agents hold attributes");
      Register_Routine
        (T, JSON_Values_Keep_Their_Structure'Access,
         "JSON values keep their structure");
      Register_Routine
        (T, A_Chain_Is_One_Edge_Per_Pair'Access,
         "A chain is one edge per pair");
      Register_Routine
        (T, Layout_Comments_And_Empty_Lists_Are_Fine'Access,
         "Layout, comments and empty lists are fine");
      Register_Routine
        (T, Keywords_May_Name_Attributes_But_Not_Steps'Access,
         "Keywords may name attributes but not steps");
      Register_Routine
        (T, Errors_Name_The_Line_And_Column'Access,
         "Errors name the line and column");
      Register_Routine
        (T, Random_Source_Never_Raises'Access,
         "Random source never raises");
   end Register_Tests;

end Synapse.Pipeline.Parser.Tests;
