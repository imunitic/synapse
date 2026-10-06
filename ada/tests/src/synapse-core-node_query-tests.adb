with Ada.Strings.Fixed;

with AUnit.Assertions;

package body Synapse.Core.Node_Query.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF   : constant Character := Character'Val (10);
   Dash : constant String    :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   function Shown (Found : Maybe_Text) return String is
     (if Found.Found then "<" & To_String (Found.Text) & ">" else "none");

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Join (A, B : String := ""; C, D : String := "") return String is
     (A & B & C & D);

   function Sample return String is
     ("---" & LF & "title: ""State machine""" & LF &
      "node_type: synapse-node" & LF & "project: widget-repo" & LF &
      "sources:" & LF & "  - path: engine/src/main/code/com/x/State.ext" & LF &
      "    hash: 1111111111111111111111111111111111111111" & LF &
      "  - path: engine/src/main/code/com/x/Transition.ext" & LF &
      "    hash: 2222222222222222222222222222222222222222" & LF &
      "grounded_in:" & LF & "  - path: engine/src/main/code/com/x/State.ext" &
      LF & "    lines: 1-2" & LF &
      "    hash: 3333333333333333333333333333333333333333" & LF &
      "sources_digest: ""df91a067""" & LF & "stale: false" & LF &
      "built_at: ""2026-08-03 16:50""" & LF & "---" & LF & LF &
      "# State machine" & LF & "<!-- synapse:generated:start -->" & LF & LF &
      "## Summary" & LF & "Prose about it." & LF & LF & "## Links" & LF &
      "- uses [[Messaging layer " & Dash & " Channel]]" & LF &
      "- part_of [[Framework]]" & LF & LF & "## Sources" & LF &
      "- `engine` (2)" & LF & "<!-- synapse:generated:end -->" & LF & LF &
      "## Notes" & LF & "hand written" & LF);

   --  ------------------------------------------------------------------

   procedure Body_Is_Between_The_Fences_Minus_The_Marker_Lines
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Inner : constant Maybe_Text := Body_Of (Sample);
      Text  : constant String     := To_String (Inner.Text);
   begin
      Assert (Inner.Found, "found");
      Assert
        (Text (Text'First .. Text'First + 10) = LF & "## Summary",
         "the blank line after the start marker survives");
      Assert
        (Text (Text'Last - 13 .. Text'Last) = "- `engine` (2)",
         "ends on the last content line, without its line feed");
      Assert (not Has (Text, "title:"), "no frontmatter");
      Assert (not Has (Text, "hand written"), "no Notes");
   end Body_Is_Between_The_Fences_Minus_The_Marker_Lines;

   procedure An_Unfenced_Node_Has_No_Body (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Old : constant String :=
        "---" & LF & "title: x" & LF & "---" & LF & LF & "# T" & LF & LF &
        "old style" & LF;
   begin
      Assert (not Body_Of (Old).Found, "none");
      Assert
        (Body_After_Frontmatter (Old) =
         LF & "# T" & LF & LF & "old style" & LF,
         "the fallback reads everything after the frontmatter");
      Assert
        (Body_After_Frontmatter ("# T" & LF) = "# T" & LF,
         "no frontmatter at all");
      Assert
        (not Body_Of ("<!-- synapse:generated:start -->" & LF).Found,
         "a start with no end");
      Assert
        (Shown
           (Body_Of
              ("<!-- synapse:generated:start -->" &
               "<!-- synapse:generated:end -->")) =
         "<>",
         "markers touching have an empty body");
   end An_Unfenced_Node_Has_No_Body;

   Briefed : constant String :=
     "---" & LF & "title: ""Widget""" & LF &
     "summary: ""Widgets, and the \""gadget\"" they feed.""" & LF &
     "crux_path: src/widget.wdg" & LF & "crux_lines: ""10-20""" & LF & "---" &
     LF & LF & "# Widget" & LF & "<!-- synapse:generated:start -->" & LF & LF &
     "## Summary" & LF & "Long prose about widgets." & LF & LF & "## Crux" &
     LF & "```" & LF & "spin()" & LF & "```" & LF & LF & "## Links" & LF &
     "- uses [[Gadget]]" & LF & LF & "## Sources" & LF & "- `src/widget.wdg`" &
     LF & "<!-- synapse:generated:end -->" & LF & LF & "## Notes" & LF &
     "hand written" & LF;

   procedure Brief_Is_Summary_Crux_Pointer_And_Links
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown (Brief (Briefed)) =
         "<summary: Widgets, and the ""gadget"" they feed." & LF &
         "crux: src/widget.wdg:10-20" & LF & "## Links" & LF &
         "- uses [[Gadget]]" & LF & ">",
         "and nothing else");
   end Brief_Is_Summary_Crux_Pointer_And_Links;

   procedure Brief_Leaves_Out_A_Part_The_Node_Lacks
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bare : constant String :=
        "---" & LF & "title: ""W""" & LF & "---" & LF &
        "<!-- synapse:generated:start -->" & LF & LF & "## Summary" & LF &
        "Prose." & LF & "<!-- synapse:generated:end -->" & LF;
   begin
      Assert (Shown (Brief (Bare)) = "<>", "nothing to say");
      Assert
        (not Brief
           ("---" & LF & "title: x" & LF & "---" & LF & LF & "old style" & LF)
           .Found,
         "none without a fence");
      Assert
        (Shown
           (Brief
              ("---" & LF & "crux_path: a.wdg" & LF & "---" & LF &
               "<!-- synapse:generated:start -->" & LF &
               "<!-- synapse:generated:end -->" & LF)) =
         "<crux: a.wdg" & LF & ">",
         "a crux with no lines");
   end Brief_Leaves_Out_A_Part_The_Node_Lacks;

   procedure Links_Last_In_The_Body_Are_Found (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown
           (Brief
              ("---" & LF & "---" & LF & "<!-- synapse:generated:start -->" &
               LF & "## Links" & LF & "- uses [[A]]" & LF &
               "<!-- synapse:generated:end -->" & LF)) =
         "<## Links" & LF & "- uses [[A]]" & LF & ">",
         "a Links section that starts the body and ends it");
      Assert
        (Shown
           (Brief
              ("---" & LF & "---" & LF & "<!-- synapse:generated:start -->" &
               LF & "## Links" & LF & LF & "<!-- synapse:generated:end -->" &
               LF)) =
         "<>",
         "an empty Links section is left out");
   end Links_Last_In_The_Body_Are_Found;

   --  ------------------------------------------------------------------

   function Ranges_Image (Found : Maybe_Ranges) return String is
      Result : Unbounded_String;
   begin
      if not Found.Valid then
         return "invalid";
      end if;
      for R of Found.Ranges loop
         Append (Result, R.First'Image & "-" & R.Last'Image & ";");
      end loop;
      return To_String (Result);
   end Ranges_Image;

   procedure Refuses (Spec : String) is
   begin
      Assert
        (Ranges_Image (Parse_Line_Ranges (Spec)) = "invalid",
         "refused: " & Spec);
   end Refuses;

   procedure Line_Ranges_Parse_And_Refuse_Anything_Malformed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Ranges_Image (Parse_Line_Ranges ("12-14,40-41,88")) =
         " 12- 14; 40- 41; 88- 88;",
         "the spelling Image produces");
      Refuses ("");
      Refuses ("a-b");
      Refuses ("5-3");
      Refuses ("0-2");
      Refuses ("1-");
      Refuses ("-2");
      Refuses ("1,,2");
      Refuses ("1-2-3");
      Refuses ("+4");
      Refuses ("1,");
      Assert
        (Parse_Line_Ranges ("99999999999999999999").Valid,
         "a number too large is clamped");
   end Line_Ranges_Parse_And_Refuse_Anything_Malformed;

   function Ranges_Of
     (Spec : String) return Text_Search.Range_Vectors.Vector is
     (Parse_Line_Ranges (Spec).Ranges);

   procedure Lines_Are_Printed_In_The_Order_Asked (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown (Lines_In (Briefed, Ranges_Of ("3-4,2"))) =
         "<summary: ""Widgets, and the \""gadget\"" they feed.""" & LF &
         "crux_path: src/widget.wdg" & LF & "title: ""Widget""" & LF & ">",
         "file lines, frontmatter included");
   end Lines_Are_Printed_In_The_Order_Asked;

   procedure An_End_Past_The_Last_Line_Is_Clamped_And_A_Start_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown (Lines_In ("a" & LF & "b" & LF, Ranges_Of ("2-9"))) =
         "<b" & LF & ">",
         "clamped");
      Assert
        (Shown (Lines_In ("a" & LF & "b" & LF, Ranges_Of ("3"))) = "none",
         "a start past the end");
      Assert
        (Shown (Lines_In ("a" & LF & "b", Ranges_Of ("2"))) = "<b" & LF & ">",
         "an unterminated last line gets its terminator");
      Assert (Shown (Lines_In ("", Ranges_Of ("1"))) = "none", "empty");
      Assert
        (Shown (Lines_In ("a" & LF & "b" & LF, Ranges_Of ("1,3"))) = "none",
         "one bad range refuses all, nothing half written");
   end An_End_Past_The_Last_Line_Is_Clamped_And_A_Start_Is_Refused;

   --  ------------------------------------------------------------------

   procedure Field_Takes_One_Scalar_And_Strips_Its_Quotes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Shown (Field (Sample, "title")) = "<State machine>", "title");
      Assert (Shown (Field (Sample, "node_type")) = "<synapse-node>", "bare");
      Assert (Shown (Field (Sample, "stale")) = "<false>", "stale");
      Assert
        (Shown (Field (Sample, "built_at")) = "<2026-08-03 16:50>",
         "with a space in it");
   end Field_Takes_One_Scalar_And_Strips_Its_Quotes;

   procedure An_Absent_Field_Is_None_And_A_Whole_Key_Matches
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Shown (Field (Sample, "crux_path")) = "none", "absent");
      Assert (Shown (Field (Sample, "nonsense")) = "none", "unknown");
      Assert
        (Shown (Field (Sample, "at")) = "none", "not a suffix of built_at");
      Assert (Shown (Field (Sample, "ources")) = "none", "not inside sources");
      Assert
        (Shown
           (Field ("---" & LF & "subtitle: x" & LF & "---" & LF, "title")) =
         "none",
         "not a longer key");
   end An_Absent_Field_Is_None_And_A_Whole_Key_Matches;

   procedure A_Field_Is_Never_Read_From_The_Body (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown
           (Field
              ("---" & LF & "title: real" & LF & "---" & LF & LF & "# T" & LF &
               "title: fake" & LF,
               "title")) =
         "<real>",
         "the frontmatter ends at its closing fence");
      Assert
        (Shown (Field ("# Just prose" & LF & "title: nope" & LF, "title")) =
         "none",
         "no frontmatter yields no fields");
   end A_Field_Is_Never_Read_From_The_Body;

   procedure A_Field_Strips_One_Quote_At_Each_End (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        "---" & LF & "title: ""ends with a quote \""""" & LF & "other: plain" &
        LF & "---" & LF;
   begin
      Assert
        (Shown (Field (Text, "title")) = "<ends with a quote \"">",
         "the escaped quote survives");
      Assert (Shown (Field (Text, "other")) = "<plain>", "a bare value");
   end A_Field_Strips_One_Quote_At_Each_End;

   procedure Scalar_Resolves_The_Escaping_Field_Leaves_Alone
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        "---" & LF &
        "summary: ""Handles \""quoted\"" input and a C:\\path.""" & LF &
        "---" & LF;
   begin
      Assert
        (Shown (Scalar (Text, "summary")) =
         "<Handles ""quoted"" input and a C:\path.>",
         "unescaped");
      Assert
        (Shown (Field (Text, "summary")) =
         "<Handles \""quoted\"" input and a C:\\path.>",
         "and Field still returns the text as written");
   end Scalar_Resolves_The_Escaping_Field_Leaves_Alone;

   procedure An_Unquoted_Scalar_Is_Returned_As_Written
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        "---" & LF & "project: widget-repo" & LF & "commit: 0123abc" & LF &
        "odd: ""a\n""" & LF & "tiny: """ & LF & "---" & LF;
   begin
      Assert (Shown (Scalar (Text, "project")) = "<widget-repo>", "bare");
      Assert (Shown (Scalar (Text, "absent")) = "none", "absent");
      Assert
        (Shown (Scalar (Text, "odd")) = "<a\n>",
         "only the two escapes the writer produces are undone");
      Assert
        (Shown (Scalar (Text, "tiny")) = "<"">",
         "a lone quote is not a quoted scalar");
   end An_Unquoted_Scalar_Is_Returned_As_Written;

   --  ------------------------------------------------------------------

   function Joined (V : Text_Lists.Vector) return String is
      Result : Unbounded_String;
   begin
      for Item of V loop
         Append (Result, Item & ";");
      end loop;
      return To_String (Result);
   end Joined;

   procedure Sources_Takes_Only_The_Sources_Block (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Joined (Sources (Sample)) =
         "engine/src/main/code/com/x/State.ext;" &
         "engine/src/main/code/com/x/Transition.ext;",
         "a grounding's path is not counted twice");
      Assert
        (Joined
           (Sources
              ("---" & LF & "title: t" & LF & "sources:" & LF & "---" & LF &
               LF & "# T" & LF)) =
         "",
         "a node that claims none");
      Assert
        (Joined (Sources ("# T" & LF & "sources:" & LF & "- path: a" & LF)) =
         "",
         "no frontmatter");
      Assert
        (Joined
           (Sources
              ("---" & LF & "sources:" & LF & "  -   path:  a b" & LF &
               "  - hash: x" & LF & "  - path: c" & LF & "---" & LF)) =
         "a b;c;",
         "blanks around the dash and the path, rows without a path skipped");
   end Sources_Takes_Only_The_Sources_Block;

   procedure Module_Counts_Are_Keyed_And_Sorted_By_Module
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Chains, Paths : Text_Lists.Vector;
      Result        : Node_Format.Module_Count_Vectors.Vector;

      procedure Add (Path : String) is
      begin
         Paths.Append (To_Unbounded_String (Path));
      end Add;
   begin
      Chains.Append (To_Unbounded_String ("src/main/code"));
      Add ("b/src/main/code/X.ext");
      Add ("a/src/main/code/Y.ext");
      Add ("a/src/main/code/Z.ext");
      Add ("docs/readme.md");
      Add ("");
      Result := Module_Counts (Paths, Chains);
      Assert
        (Natural (Result.Length) = 3, "three modules; empty path skipped");
      Assert
        (To_String (Result (1).Module) = "a" and then Result (1).Count = 2,
         "a, twice");
      Assert (To_String (Result (2).Module) = "b", "then b");
      Assert (To_String (Result (3).Module) = "docs", "then docs");
      Assert
        (Module_Counts (Text_Lists.Vectors.Empty_Vector, Chains).Is_Empty,
         "no paths");
   end Module_Counts_Are_Keyed_And_Sorted_By_Module;

   --  ------------------------------------------------------------------

   function Edges_Image (V : Edge_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for E of V loop
         Append (Result, E.Relation & "->" & E.Target & ";");
      end loop;
      return To_String (Result);
   end Edges_Image;

   procedure Edges_Are_The_Links_Section_Only (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Edges_Image (Edges (Sample)) =
         "uses->Messaging layer " & Dash & " Channel;part_of->Framework;",
         "both, and not the Sources rows after them");
   end Edges_Are_The_Links_Section_Only;

   procedure A_Link_With_No_Relation_Is_Not_An_Edge
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Edges_Image
           (Edges
              ("## Links" & LF & "- [[Target]]" & LF & "- `mod` (3)" & LF &
               "- uses [[Real]]" & LF)) =
         "uses->Real;",
         "a bare link and a Sources row are not edges");
      Assert
        (Edges_Image
           (Edges
              ("## Links" & LF & "- uses [[]]" & LF & "- uses [[open" & LF &
               "x [[Y]]" & LF & "- a b  [[Z|shown]]" & Character'Val (13) &
               LF)) =
         "a b->Z|shown;",
         "an empty target, an unclosed link and a line with no dash; " &
         "display text stays in the target");
   end A_Link_With_No_Relation_Is_Not_An_Edge;

   procedure A_Node_With_No_Links_Section_Has_No_Edges
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Edges
           ("# T" & LF & LF & "## Summary" & LF & "prose" & LF & LF &
            "## Sources" & LF & "- `a` (1)" & LF)
           .Is_Empty,
         "none");
      Assert (Edges ("").Is_Empty, "empty");
      Assert
        (Edges ("- uses [[A]]" & LF).Is_Empty,
         "a dash line outside the section");
   end A_Node_With_No_Links_Section_Has_No_Edges;

   procedure Written_Nodes_Read_Back (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Joined_Text : constant String := Join (Briefed);
   begin
      Assert
        (Shown (Field (Joined_Text, "crux_lines")) = "<10-20>",
         "a field of a node");
      Assert (Length (Body_Of (Joined_Text).Text) > 0, "and its body");
   end Written_Nodes_Read_Back;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Node_Query");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Body_Is_Between_The_Fences_Minus_The_Marker_Lines'Access,
         "Body is between the fences, minus the marker lines");
      Register_Routine
        (T, An_Unfenced_Node_Has_No_Body'Access,
         "An unfenced node has no body");
      Register_Routine
        (T, Brief_Is_Summary_Crux_Pointer_And_Links'Access,
         "Brief is the summary, the crux pointer and the Links block");
      Register_Routine
        (T, Brief_Leaves_Out_A_Part_The_Node_Lacks'Access,
         "Brief leaves out a part the node lacks");
      Register_Routine
        (T, Links_Last_In_The_Body_Are_Found'Access,
         "Links that start or end the body are found");
      Register_Routine
        (T, Line_Ranges_Parse_And_Refuse_Anything_Malformed'Access,
         "Line ranges parse, and anything malformed is refused");
      Register_Routine
        (T, Lines_Are_Printed_In_The_Order_Asked'Access,
         "Lines are printed in the order asked");
      Register_Routine
        (T, An_End_Past_The_Last_Line_Is_Clamped_And_A_Start_Is_Refused'Access,
         "An end past the last line is clamped and a start is refused");
      Register_Routine
        (T, Field_Takes_One_Scalar_And_Strips_Its_Quotes'Access,
         "Field takes one scalar and strips its quotes");
      Register_Routine
        (T, An_Absent_Field_Is_None_And_A_Whole_Key_Matches'Access,
         "An absent field is none and a whole key matches");
      Register_Routine
        (T, A_Field_Is_Never_Read_From_The_Body'Access,
         "A field is never read from the body");
      Register_Routine
        (T, A_Field_Strips_One_Quote_At_Each_End'Access,
         "A field strips one quote at each end");
      Register_Routine
        (T, Scalar_Resolves_The_Escaping_Field_Leaves_Alone'Access,
         "Scalar resolves the escaping Field leaves alone");
      Register_Routine
        (T, An_Unquoted_Scalar_Is_Returned_As_Written'Access,
         "An unquoted scalar is returned as written");
      Register_Routine
        (T, Sources_Takes_Only_The_Sources_Block'Access,
         "Sources takes only the sources block");
      Register_Routine
        (T, Module_Counts_Are_Keyed_And_Sorted_By_Module'Access,
         "Module counts are keyed and sorted by module");
      Register_Routine
        (T, Edges_Are_The_Links_Section_Only'Access,
         "Edges are the Links section only");
      Register_Routine
        (T, A_Link_With_No_Relation_Is_Not_An_Edge'Access,
         "A link with no relation is not an edge");
      Register_Routine
        (T, A_Node_With_No_Links_Section_Has_No_Edges'Access,
         "A node with no Links section has no edges");
      Register_Routine
        (T, Written_Nodes_Read_Back'Access, "A node reads back");
   end Register_Tests;

end Synapse.Core.Node_Query.Tests;
