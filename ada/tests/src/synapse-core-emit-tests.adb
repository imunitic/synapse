with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.Graph_Model;
with Synapse.Core.Node_Format;

package body Synapse.Core.Emit.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Ends (Text, Suffix : String) return Boolean is
     (Text'Length >= Suffix'Length
      and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix);

   function Shown (Found : Maybe_Text) return String is
     (if Found.Found then "<" & To_String (Found.Text) & ">" else "none");

   --  ------------------------------------------------------------------
   --  Titles and directives

   procedure A_Title_Is_Sanitized_Only_Where_It_Must_Be
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (File_Title ("World " & Dash & " entity core") =
         "World " & Dash & " entity core",
         "an em dash is legal");
      Assert
        (File_Title ("a/b:c*d?e""f<g>h|i") = "a_b_c_d_e_f_g_h_i",
         "every illegal character");
      Assert (File_Title ("") = "", "empty");
   end A_Title_Is_Sanitized_Only_Where_It_Must_Be;

   procedure A_Directive_Is_Found_Whole (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text : constant String :=
        "prose" & LF & "<!-- crux: src/a.wdg 10-12 -->" & LF & "more" & LF;
   begin
      Assert
        (Shown (Find_Directive (Text, Kind_Crux)) =
         "<<!-- crux: src/a.wdg 10-12 -->>",
         "whole, comment markers too");
      Assert
        (Shown (Find_Directive (Text, Kind_Grounded)) = "none",
         "another keyword is not found");
   end A_Directive_Is_Found_Whole;

   procedure Every_Directive_Returned_Parses_Again
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        "prose" & LF & "<!-- crux: src/a.wdg 10-12 -->" & LF &
        "more <!-- grounded_in: src/b.wdg 1-2 --> text" & LF &
        "and <!-- grounded_in: src/c.wdg 3-4 -->" & LF;

      function Reparses (Whole, Keyword : String) return Boolean is
        (Directive_Arg (Whole (Whole'First + 4 .. Whole'Last - 3), Keyword)
           .Found);

      Grounded : constant Text_Lists.Vector :=
        Directives (Text, Kind_Grounded);
   begin
      Assert
        (Reparses
           (To_String (Find_Directive (Text, Kind_Crux).Text), Kind_Crux),
         "the first crux");
      Assert (Natural (Grounded.Length) = 2, "both groundings");
      for Whole of Grounded loop
         Assert (Reparses (To_String (Whole), Kind_Grounded), "re-parses");
      end loop;
      Assert
        (To_String (Grounded.First_Element) =
         "<!-- grounded_in: src/b.wdg 1-2 -->",
         "in order");
   end Every_Directive_Returned_Parses_Again;

   procedure A_Comment_That_Is_Not_A_Directive_Is_Prose
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown (Find_Directive ("<!-- cruxes are nice -->", Kind_Crux)) =
         "none",
         "no colon");
      Assert
        (Shown (Find_Directive ("<!-- TODO -->", Kind_Crux)) = "none",
         "another word");
      Assert
        (Shown (Directive_Arg ("  crux :x", Kind_Crux)) = "none",
         "a space before the colon");
      Assert
        (Shown (Directive_Arg ("crux:", Kind_Crux)) = "<>", "no argument");
      Assert
        (Shown
           (Directive_Arg
              (" " & Character'Val (9) & "crux:  a b  ", Kind_Crux)) =
         "<a b>",
         "trimmed");
   end A_Comment_That_Is_Not_A_Directive_Is_Prose;

   procedure Odd_Comment_Shapes_Do_Not_Break_The_Scan
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown (Find_Directive ("<!-->", Kind_Crux)) = "none",
         "a comment that closes inside its own opener");
      Assert
        (Shown (Find_Directive ("<!--> x <!-- crux: a 1-2 -->", Kind_Crux)) =
         "<<!-- crux: a 1-2 -->>",
         "the closing marker is looked for after the opener");
      Assert
        (Shown (Find_Directive ("<!-- crux: a 1-2", Kind_Crux)) = "none",
         "never closed");
      Assert (Shown (Find_Directive ("", Kind_Crux)) = "none", "empty");
      Assert
        (Strip_Grounded ("<!--> x") = "<!--> x", "stripping, same shapes");
   end Odd_Comment_Shapes_Do_Not_Break_The_Scan;

   --  ------------------------------------------------------------------
   --  Sections

   procedure A_Section_Stops_At_The_Next_Heading_Or_The_Fence
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Whole : constant String :=
        "# Title" & LF & "## Summary" & LF & "prose" & LF & "## Crux" & LF &
        "<!-- crux: src/a.wdg 10-12 -->" & LF & "## Links" & LF &
        "- uses [[X]]" & LF;
   begin
      Assert
        (Shown (Section (Whole, "Crux")) =
         "<<!-- crux: src/a.wdg 10-12 -->" & LF & ">",
         "up to the next heading");
      Assert
        (Shown
           (Section
              ("## Crux" & LF & "<!-- crux: none -->" & LF & "## Notes" & LF,
               "Crux")) =
         "<<!-- crux: none -->" & LF & ">",
         "from the first line");
      Assert
        (Shown
           (Section
              ("## Crux" & LF & "<!-- crux: none -->" & LF &
               Node_Format.Generated_End & LF & LF & "## Notes" & LF &
               "hand written" & LF,
               "Crux")) =
         "<<!-- crux: none -->" & LF & ">",
         "up to the closing fence");
      Assert
        (Shown
           (Section ("## Summary" & LF & "prose" & LF & "## Crux", "Crux")) =
         "<>",
         "a last heading with no content");
      Assert
        (Shown
           (Section ("## Crux" & Character'Val (13) & LF & "x" & LF, "Crux")) =
         "<x" & LF & ">",
         "a heading line that ends in a carriage return");
   end A_Section_Stops_At_The_Next_Heading_Or_The_Fence;

   procedure A_Missing_Heading_Is_Not_Found (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown (Section ("## Summary" & LF & "prose" & LF, "Crux")) = "none",
         "missing");
      Assert
        (Shown
           (Section ("## Cruxes and caveats" & LF & "prose" & LF, "Crux")) =
         "none",
         "a longer heading is not the heading searched for");
      Assert (Shown (Section ("", "Crux")) = "none", "empty");
   end A_Missing_Heading_Is_Not_Found;

   procedure A_Quoted_Directive_Outside_The_Section_Is_Not_Found
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Whole  : constant String     :=
        "## Summary" & LF &
        "A crux directive looks like `<!-- crux: path/to/file.ext 10-20 -->`" &
        " in prose." & LF & "## Crux" & LF &
        "<!-- crux: src/real.wdg 5-8 -->" & LF & "## Notes" & LF;
      Scoped : constant Maybe_Text := Section (Whole, "Crux");
   begin
      Assert
        (Shown (Find_Directive (To_String (Scoped.Text), Kind_Crux)) =
         "<<!-- crux: src/real.wdg 5-8 -->>",
         "scoped to the section");
      Assert
        (Shown (Find_Directive (Whole, Kind_Crux)) =
         "<<!-- crux: path/to/file.ext 10-20 -->>",
         "an unscoped scan finds the quoted one first");
   end A_Quoted_Directive_Outside_The_Section_Is_Not_Found;

   --  ------------------------------------------------------------------
   --  Spans

   function Image_Of (Found : Maybe_Span) return String is
     (if Found.Found then
        To_String (Found.Value.Path) & ":" & Found.Value.First'Image & ":" &
        Found.Value.Last'Image
      else "none");

   procedure A_Span_Parses_With_L_Prefixes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Plain : constant Maybe_Span := Parse_Span ("src/a.wdg 412-419");
   begin
      Assert (Image_Of (Plain) = "src/a.wdg: 412: 419", "plain");
      Assert (Lines (Plain.Value) = 8, "inclusive");
      Assert
        (Image_Of (Parse_Span ("src/a.wdg L10-L12")) = "src/a.wdg: 10: 12",
         "L on either bound");
      Assert
        (Image_Of (Parse_Span ("src/a.wdg" & Character'Val (9) & "5-6")) =
         "src/a.wdg: 5: 6",
         "a tab separates too");
      Assert
        (Image_Of (Parse_Span ("a b.wdg  7-9")) = "a: 7: 9",
         "the path ends at the first blank");
   end A_Span_Parses_With_L_Prefixes;

   procedure A_Malformed_Span_Is_Rejected (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Image_Of (Parse_Span ("src/a.wdg")) = "none", "no range");
      Assert (Image_Of (Parse_Span ("src/a.wdg 412")) = "none", "one bound");
      Assert (Image_Of (Parse_Span ("src/a.wdg abc-def")) = "none", "letters");
      Assert
        (Image_Of (Parse_Span ("src/a.wdg +5-9")) = "none",
         "a sign is not a digit");
      Assert (Image_Of (Parse_Span ("src/a.wdg -5-9")) = "none", "a minus");
      Assert (Image_Of (Parse_Span ("src/a.wdg 5-")) = "none", "no end");
      Assert (Image_Of (Parse_Span ("src/a.wdg -9")) = "none", "no start");
      Assert (Image_Of (Parse_Span (" 5-9")) = "none", "no path");
      Assert (Image_Of (Parse_Span ("")) = "none", "empty");
      Assert
        (Image_Of (Parse_Span ("p " & [1 .. 70 => '1'])) = "none",
         "a range of more than 64 characters");
   end A_Malformed_Span_Is_Rejected;

   procedure A_Three_Bound_Range_Reads_First_To_Last
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Image_Of (Parse_Span ("f.wdg 10-20-30")) = "f.wdg: 10: 30",
         "first to last");
   end A_Three_Bound_Range_Reads_First_To_Last;

   procedure A_Huge_Bound_Is_Clamped_And_Reads_As_Out_Of_Range
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Huge  : constant Maybe_Span :=
        Parse_Span ("a.wdg 1-99999999999999999999");
      Paths : Text_Lists.Vector;
   begin
      Paths.Append (To_Unbounded_String ("a.wdg"));
      Assert (Huge.Found and then Huge.Value.Last = Natural'Last, "clamped");
      Assert
        (Check_Span (Huge.Value, Crux, Paths, 100).Kind = Out_Of_Range,
         "out of range, not malformed");
   end A_Huge_Bound_Is_Clamped_And_Reads_As_Out_Of_Range;

   function Span_Of (Path : String; First, Last : Natural) return Span is
     (Path => To_Unbounded_String (Path), First => First, Last => Last);

   function Paths_Of (A, B, C : String := "") return Text_Lists.Vector is
      Result : Text_Lists.Vector;

      procedure Add (Path : String) is
      begin
         if Path /= "" then
            Result.Append (To_Unbounded_String (Path));
         end if;
      end Add;
   begin
      Add (A);
      Add (B);
      Add (C);
      return Result;
   end Paths_Of;

   procedure The_Caps_Differ_By_Kind (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Paths : constant Text_Lists.Vector := Paths_Of ("a.wdg");
   begin
      Assert
        (Check_Span (Span_Of ("a.wdg", 1, 20), Crux, Paths, 100).Kind = None,
         "twenty lines of a crux");
      declare
         Too : constant Span_Problem :=
           Check_Span (Span_Of ("a.wdg", 1, 21), Crux, Paths, 100);
      begin
         Assert
           (Too.Kind = Too_Long and then Too.Line_Count = 21,
            "twenty-one, counted inclusive");
      end;
      Assert
        (Check_Span (Span_Of ("a.wdg", 1, 40), Grounded, Paths, 100).Kind =
         None,
         "forty lines of a grounding");
      Assert
        (Check_Span (Span_Of ("a.wdg", 1, 41), Grounded, Paths, 100).Kind =
         Too_Long,
         "forty-one");
      Assert (Cap (Crux) = 20 and then Cap (Grounded) = 40, "the caps");
      Assert
        (Keyword (Crux) = "crux" and then Keyword (Grounded) = "grounded_in",
         "the keywords");
   end The_Caps_Differ_By_Kind;

   procedure A_Span_Must_Be_Claimed_And_Fit_The_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Paths : constant Text_Lists.Vector :=
        Paths_Of ("a.wdg", "b.wdg", "c.wdg");
   begin
      Assert
        (Check_Span (Span_Of ("z.wdg", 1, 2), Crux, Paths, 100).Kind =
         Not_Claimed,
         "not one of the node's sources");
      Assert
        (Check_Span (Span_Of ("a.wdg", 1, 2), Crux, Paths, 100).Kind = None,
         "the first of three");
      Assert
        (Check_Span (Span_Of ("c.wdg", 1, 2), Crux, Paths, 100).Kind = None,
         "the last of three");
      Assert
        (Check_Span (Span_Of ("b.wdg", 1, 2), Crux, Paths, 100).Kind = None,
         "the middle");
      Assert
        (Check_Span (Span_Of ("aa.wdg", 1, 2), Crux, Paths, 100).Kind =
         Not_Claimed,
         "between two");
      declare
         Past : constant Span_Problem :=
           Check_Span (Span_Of ("b.wdg", 99, 101), Crux, Paths, 100);
      begin
         Assert
           (Past.Kind = Out_Of_Range and then Past.Total_Lines = 100,
            "past the end, with the file's size");
      end;
      Assert
        (Check_Span (Span_Of ("b.wdg", 5, 4), Crux, Paths, 100).Kind =
         Out_Of_Range,
         "backwards");
      Assert
        (Check_Span (Span_Of ("b.wdg", 0, 4), Crux, Paths, 100).Kind =
         Out_Of_Range,
         "from line zero");
      Assert
        (Check_Span (Span_Of ("b.wdg", 1, 100), Grounded, Paths, 100).Kind =
         Too_Long,
         "too long, but inside the file");
      Assert
        (Check_Span (Span_Of ("a.wdg", 1, 2), Crux, Paths_Of, 100).Kind =
         Not_Claimed,
         "a node with no sources claims nothing");
   end A_Span_Must_Be_Claimed_And_Fit_The_File;

   --  ------------------------------------------------------------------
   --  Rewriting a body

   procedure A_Crux_Block_Is_The_Fence_The_Slice_And_A_Provenance_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Crux_Block
           (Span_Of ("a/b.wdg", 4, 5), "  x = 1;" & LF & "  return x;" & LF,
            "widget") =
         "```widget" & LF & "  x = 1;" & LF & "  return x;" & LF & "```" & LF &
         Dash & " `a/b.wdg`:4-5" & LF,
         "the block");
      Assert
        (Crux_Block (Span_Of ("a.txt", 1, 1), "last line", "") =
         "```" & LF & "last line" & LF & "```" & LF & Dash & " `a.txt`:1-1" &
         LF,
         "no trailing line feed: the fence still gets its own line");
      Assert
        (Crux_Block (Span_Of ("a.txt", 1, 1), "", "") =
         "```" & LF & "```" & LF & Dash & " `a.txt`:1-1" & LF,
         "an empty slice");
   end A_Crux_Block_Is_The_Fence_The_Slice_And_A_Provenance_Line;

   procedure Substitution_Replaces_The_Whole_Line (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Substitute_Line
           ("## Crux" & LF & "  <!-- crux: a.wdg 1-2 -->" & LF & "after" & LF,
            "<!-- crux: a.wdg 1-2 -->", "```" & LF & "x" & LF & "```" & LF) =
         "## Crux" & LF & "```" & LF & "x" & LF & "```" & LF & "after" & LF,
         "the indented line goes, with its indentation");
      Assert
        (Substitute_Line
           ("<!-- m -->" & LF & "<!-- m -->" & LF, "<!-- m -->", "X" & LF) =
         "X" & LF & "<!-- m -->" & LF,
         "only the first");
      Assert
        (Substitute_Line ("no marker" & LF, "<!-- m -->", "X") =
         "no marker" & LF,
         "nothing to replace");
      Assert
        (Substitute_Line ("<!-- m -->", "<!-- m -->", "X") = "X",
         "a text of one line");
      Assert (Substitute_Line ("", "m", "X") = "", "empty");
   end Substitution_Replaces_The_Whole_Line;

   procedure A_Grounding_Disappears_And_One_In_Prose_Is_Cut_Out
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Strip_Grounded
           ("## Summary" & LF & "  <!-- grounded_in: a.wdg 10-14 -->" & LF &
            "It holds <!-- grounded_in: b.wdg 1-2 --> because of the test." &
            LF & "end" & LF) =
         "## Summary" & LF & "It holds  because of the test." & LF & "end" &
         LF,
         "a line of its own, and a cut");
      Assert
        (Strip_Grounded
           ("<!-- keep me -->" & LF & "<!-- grounded_in: a 1-2 -->" & LF) =
         "<!-- keep me -->" & LF,
         "other comments stay");
      Assert
        (Strip_Grounded
           ("a <!-- keep --> b <!-- grounded_in: x 1-2 --> c" & LF) =
         "a <!-- keep --> b  c" & LF,
         "a comment before the grounding");
      Assert
        (Strip_Grounded
           ("<!-- grounded_in: a 1-2 --> <!-- grounded_in: b 3-4 -->") =
         " ",
         "two on one line are cut out of it, not dropped");
      Assert (Strip_Grounded ("") = "", "empty");
   end A_Grounding_Disappears_And_One_In_Prose_Is_Cut_Out;

   procedure Blank_Edges_Are_Trimmed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Trim_Blank_Edges
           (LF & LF & "  " & LF & "## Summary" & LF & "x" & LF & LF & " " &
            LF) =
         "## Summary" & LF & "x",
         "both edges");
      Assert (Trim_Blank_Edges ("x") = "x", "nothing to trim");
      Assert
        (Trim_Blank_Edges (LF & " " & LF & Character'Val (9) & LF) = "",
         "only blanks");
      Assert (Trim_Blank_Edges ("") = "", "empty");
      Assert
        (Trim_Blank_Edges ("a" & LF & LF & "b") = "a" & LF & LF & "b",
         "inner blank lines stay");
      Assert (Trim_Blank_Edges ("  x" & LF) = "  x", "indentation stays");
      declare
         Once : constant String := Trim_Blank_Edges (LF & "x" & LF & LF);
      begin
         Assert (Trim_Blank_Edges (Once) = Once, "idempotent");
      end;
   end Blank_Edges_Are_Trimmed;

   procedure A_Summary_Is_Escaped_For_A_Quoted_Scalar
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Yaml_Quoted ("a ""quoted"" path C:\x") = "a \""quoted\"" path C:\\x",
         "the backslash is escaped, once");
      Assert
        (Yaml_Quoted ("a" & LF & "b" & Character'Val (13) & "c") = "a\nb\rc",
         "line breaks");
      Assert
        (Yaml_Quoted ("plain " & Dash) = "plain " & Dash,
         "other characters as they are");
   end A_Summary_Is_Escaped_For_A_Quoted_Scalar;

   --  ------------------------------------------------------------------
   --  The note

   Ones   : constant String := [1 .. 40 => '1'];
   Twos   : constant String := [1 .. 40 => '2'];
   Threes : constant String := [1 .. 40 => '3'];
   Fours  : constant String := [1 .. 40 => '4'];
   Fives  : constant String := [1 .. 40 => '5'];

   function Source (Path, Hex : String) return Graph_Model.Source_Ref is
     (Path  => To_Unbounded_String (Path),
      Which => Graph_Model.Hash_From_Hex (Hex).Value);

   function Counted (Module : String) return Node_Format.Module_Count is
     (Module => To_Unbounded_String (Module), Count => 1);

   function Base_Note return Note is
      Result : Note;
   begin
      Result.Title   := To_Unbounded_String ("State machine");
      Result.Summary := To_Unbounded_String ("How states advance");
      Result.Project := To_Unbounded_String ("widget-repo");
      Result.Branch  := To_Unbounded_String ("main");
      Result.Sources.Append (Source ("a/A.wdg", Ones));
      Result.Sources.Append (Source ("b/B.wdg", Twos));
      Result.Digest   := To_Unbounded_String ("df91a067");
      Result.Built_At := To_Unbounded_String ("2026-08-12 18:00");
      Result.Commit   :=
        To_Unbounded_String ("0123456789abcdef0123456789abcdef01234567");
      Result.Modules.Append (Counted ("a"));
      Result.Modules.Append (Counted ("b"));
      Result.Prose := To_Unbounded_String ("## Summary" & LF & "prose" & LF);
      return Result;
   end Base_Note;

   procedure A_Fresh_Node_Gets_An_Empty_Notes_Section
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Image (Base_Note) =
         "---" & LF & "schema: graph-node/v1" & LF &
         "title: ""State machine""" & LF & "summary: ""How states advance""" &
         LF & "node_type: synapse-node" & LF & "project: widget-repo" & LF &
         "branch: main" & LF & "sources_digest: df91a067" & LF &
         "stale: false" & LF & "built_at: ""2026-08-12 18:00""" & LF &
         "commit: 0123456789abcdef0123456789abcdef01234567" & LF & "sources:" &
         LF & "  - path: a/A.wdg" & LF & "    hash: " & Ones & LF &
         "  - path: b/B.wdg" & LF & "    hash: " & Twos & LF & "---" & LF &
         LF & "# State machine" & LF & "<!-- synapse:generated:start -->" &
         LF & LF & "## Summary" & LF & "prose" & LF & LF & "## Sources" & LF &
         "- `a/A.wdg`" & LF & "- `b/B.wdg`" & LF &
         "<!-- synapse:generated:end -->" & LF & LF & "## Notes" & LF & LF,
         "the whole note, byte for byte");
   end A_Fresh_Node_Gets_An_Empty_Notes_Section;

   procedure A_Title_With_A_Quote_And_A_Newline_Cannot_Hijack_A_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Evil : Note := Base_Note;
   begin
      Evil.Title := To_Unbounded_String ("Evil""" & LF & "stale: true");
      declare
         Text        : constant String := Image (Evil);
         Frontmatter : constant String :=
           Text
             (Text'First ..
                  Ada.Strings.Fixed.Index (Text, LF & "---" & LF & LF));
      begin
         Assert
           (Has (Text, "title: ""Evil\""\nstale: true""" & LF),
            "the title stays on one line");
         Assert
           (not Has (Frontmatter, LF & "stale: true"),
            "no line of the frontmatter says stale: true");
         Assert (Has (Frontmatter, LF & "stale: false"), "the real field");
      end;
   end A_Title_With_A_Quote_And_A_Newline_Cannot_Hijack_A_Field;

   procedure Every_Scalar_Field_Comes_Before_The_Sources_List
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String := Image (Base_Note);

      function At_Key (Key : String) return Natural is
        (Ada.Strings.Fixed.Index (Text, LF & Key));

      Order : constant array (1 .. 10) of Natural :=
        [At_Key ("title:"), At_Key ("summary:"), At_Key ("node_type:"),
        At_Key ("project:"), At_Key ("branch:"), At_Key ("sources_digest:"),
        At_Key ("stale:"), At_Key ("built_at:"), At_Key ("commit:"),
        At_Key ("sources:")];
   begin
      Assert
        (Has (Text (1 .. 30), "---" & LF & "schema: graph-node/v1" & LF),
         "the schema first");
      for I in Order'First .. Order'Last loop
         Assert (Order (I) > 0, "present" & I'Image);
         if I > Order'First then
            Assert (Order (I - 1) < Order (I), "in order at" & I'Image);
         end if;
      end loop;
   end Every_Scalar_Field_Comes_Before_The_Sources_List;

   procedure Sources_List_Paths_Below_The_Threshold_And_Roll_Up_At_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Five : Note := Base_Note;
   begin
      Assert
        (Has
           (Image (Base_Note),
            LF & "## Sources" & LF & "- `a/A.wdg`" & LF & "- `b/B.wdg`" & LF),
         "paths below the threshold");

      Five.Sources.Append (Source ("c/C.wdg", Threes));
      Five.Sources.Append (Source ("d/D.wdg", Fours));
      Five.Sources.Append (Source ("e/E.wdg", Fives));
      Five.Modules.Append (Counted ("c"));
      Five.Modules.Append (Counted ("d"));
      Five.Modules.Append (Counted ("e"));
      Assert
        (Has
           (Image (Five),
            LF & "## Sources" & LF & "- `a` (1)" & LF & "- `b` (1)" & LF &
            "- `c` (1)" & LF & "- `d` (1)" & LF & "- `e` (1)" & LF),
         "the module rollup at the threshold");
      Assert
        (not Has (Image (Five), "- `a/A.wdg`"), "and no paths in the mirror");
   end Sources_List_Paths_Below_The_Threshold_And_Roll_Up_At_It;

   procedure An_Existing_Tail_Is_Reemitted (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Kept : Note := Base_Note;
   begin
      Kept.Tail :=
        To_Unbounded_String
          (LF & "## Notes" & LF & "hand written, must survive");
      Assert
        (Ends
           (Image (Kept),
            Node_Format.Generated_End & LF & LF & "## Notes" & LF &
            "hand written, must survive" & LF),
         "the tail, then one line feed");
   end An_Existing_Tail_Is_Reemitted;

   procedure An_Absent_Commit_Omits_The_Field (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      No_Commit : Note := Base_Note;
   begin
      No_Commit.Commit := Null_Unbounded_String;
      Assert (not Has (Image (No_Commit), "commit:"), "no commit field");
   end An_Absent_Commit_Omits_The_Field;

   procedure Crux_And_Grounded_Fields_Appear_Only_When_There_Are_Any
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Full : Note := Base_Note;
   begin
      Assert
        (not Has (Image (Full), "crux_path:")
         and then not Has (Image (Full), "grounded_in:"),
         "neither by default");
      Full.Has_Crux := True;
      Full.Crux     :=
        (Path  => To_Unbounded_String ("a/A.wdg"),
         Lines => To_Unbounded_String ("10-12"));
      Full.Grounded.Append
        (Grounded_Row'
           (Path   => To_Unbounded_String ("a/A.wdg"),
            Lines  => To_Unbounded_String ("1-4"),
            Digest => To_Unbounded_String ("aaaa")));
      Full.Grounded.Append
        (Grounded_Row'
           (Path   => To_Unbounded_String ("b/B.wdg"),
            Lines  => To_Unbounded_String ("7-9"),
            Digest => To_Unbounded_String ("bbbb")));
      declare
         Text : constant String := Image (Full);
      begin
         Assert
           (Has
              (Text, "crux_path: a/A.wdg" & LF & "crux_lines: ""10-12""" & LF),
            "the crux pointer");
         Assert
           (Has
              (Text,
               "grounded_in:" & LF & "  - path: a/A.wdg" & LF &
               "    lines: ""1-4""" & LF & "    digest: aaaa" & LF &
               "  - path: b/B.wdg" & LF),
            "the grounding rows");
         Assert
           (Ada.Strings.Fixed.Index (Text, "grounded_in:") <
            Ada.Strings.Fixed.Index (Text, LF & "sources:"),
            "before the sources list");
      end;
   end Crux_And_Grounded_Fields_Appear_Only_When_There_Are_Any;

   procedure A_Recovered_Body_Written_Back_Produces_The_Same_Bytes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      First : Note := Base_Note;
   begin
      First.Prose :=
        To_Unbounded_String
          ("## Summary" & LF & "prose" & LF & LF & "## Links" & LF &
           "- uses [[Other]]" & LF);
      declare
         Written   : constant String                   := Image (First);
         Parts     : constant Node_Format.Split_Result :=
           Node_Format.Split (Written);
         Head      : constant String := To_String (Parts.Head);
         Marker    : constant Natural                  :=
           Ada.Strings.Fixed.Index (Head, Node_Format.Generated_Start);
         Recovered : constant String := To_String (Parts.Tail) & "";
         pragma Unreferenced (Marker, Recovered);
         Inside     : constant String  :=
           Written
             (Written'First + Head'Length ..
                  Written'Last - Length (Parts.Tail));
         Sources_At : constant Natural :=
           Ada.Strings.Fixed.Index (Inside, LF & "## Sources" & LF);
         Second     : Note             := First;
      begin
         Assert (Parts.Fenced, "fenced");
         Assert (Sources_At > 0, "the mirror is in the generated region");
         Second.Prose :=
           To_Unbounded_String (Inside (Inside'First .. Sources_At - 1));
         Assert
           (Image (Second) = Written,
            "the body without its mirror writes back the same bytes");
      end;
   end A_Recovered_Body_Written_Back_Produces_The_Same_Bytes;

   --  ------------------------------------------------------------------
   --  Staleness, the crux copy and the notes

   function Stale (Text : String) return String is
      Result  : Unbounded_String;
      Changed : Boolean;
   begin
      Set_Stale_True (Text, Result, Changed);
      return (if Changed then "changed:" else "same:") & To_String (Result);
   end Stale;

   procedure Set_Stale_Rewrites_One_Line (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Stale
           ("---" & LF & "title: ""T""" & LF & "sources:" & LF &
            "  - path: a" & LF & "    hash: 1111111111" & LF & "stale: false" &
            LF & "---" & LF & LF & "# T" & LF & "body" & LF) =
         "changed:---" & LF & "title: ""T""" & LF & "sources:" & LF &
         "  - path: a" & LF & "    hash: 1111111111" & LF & "stale: true" &
         LF & "---" & LF & LF & "# T" & LF & "body" & LF,
         "one line, every other byte as it was");
   end Set_Stale_Rewrites_One_Line;

   procedure Set_Stale_Handles_Crlf (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      CR : constant Character := Character'Val (13);
   begin
      Assert
        (Stale
           ("---" & CR & LF & "title: ""T""" & CR & LF & "stale: false" & CR &
            LF & "---" & CR & LF & CR & LF & "# T" & CR & LF & "body" & CR &
            LF) =
         "changed:---" & CR & LF & "title: ""T""" & CR & LF & "stale: true" &
         CR & LF & "---" & CR & LF & CR & LF & "# T" & CR & LF & "body" & CR &
         LF,
         "a CRLF file keeps its endings");
      Assert
        (Stale ("---" & CR & LF & "title: ""T""" & CR & LF & "---" & CR & LF) =
         "changed:---" & CR & LF & "title: ""T""" & CR & LF & "stale: true" &
         CR & LF & "---" & CR & LF,
         "a field added to a CRLF file gets the same ending");
   end Set_Stale_Handles_Crlf;

   procedure An_Already_Stale_Node_Reports_No_Change
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        "---" & LF & "title: ""T""" & LF & "stale: true" & LF & "---" & LF &
        LF & "body" & LF;
   begin
      Assert (Stale (Text) = "same:" & Text, "no change, so no write");
      Assert
        (Stale ("---" & LF & "stale:true" & LF & "---" & LF) =
         "same:---" & LF & "stale: true" & LF & "---" & LF,
         "the value is compared trimmed");
   end An_Already_Stale_Node_Reports_No_Change;

   procedure A_Node_With_No_Stale_Field_Gains_One (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Stale ("---" & LF & "title: ""T""" & LF & "---" & LF & "body" & LF) =
         "changed:---" & LF & "title: ""T""" & LF & "stale: true" & LF &
         "---" & LF & "body" & LF,
         "before the closing marker");
   end A_Node_With_No_Stale_Field_Gains_One;

   procedure A_File_With_No_Frontmatter_Is_Left_Alone
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Stale ("# Just prose" & LF & "stale: false" & LF) = "same:",
         "nothing written");
      Assert (Stale ("") = "same:", "empty");
   end A_File_With_No_Frontmatter_Is_Left_Alone;

   procedure Only_The_Frontmatters_Stale_Line_Is_Touched
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Stale
           ("---" & LF & "title: ""T""" & LF & "---" & LF & "stale: false" &
            LF) =
         "changed:---" & LF & "title: ""T""" & LF & "stale: true" & LF &
         "---" & LF & "stale: false" & LF,
         "a stale line in the body is body");
   end Only_The_Frontmatters_Stale_Line_Is_Touched;

   procedure Fenced_Text_Is_A_Toggle_Not_A_Parser (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Fenced_Text
           ("# T" & LF & "## Crux" & LF & "```widget" & LF & "x = 1;" & LF &
            "return x;" & LF & "```" & LF & Dash & " `a.wdg`:4-5" & LF) =
         "x = 1;" & LF & "return x;" & LF,
         "one block");
      Assert
        (Fenced_Text
           ("```" & LF & "a" & LF & "```" & LF & "text" & LF & "```" & LF &
            "b" & LF & "```" & LF) =
         "a" & LF & "b" & LF,
         "several blocks all contribute");
      Assert (Fenced_Text ("no fence" & LF) = "", "none");
      Assert
        (Fenced_Text ("```" & LF & "open") = "open" & LF,
         "an unclosed fence runs to the end");
   end Fenced_Text_Is_A_Toggle_Not_A_Parser;

   function Fence (Prose : String) return String is
     ("# T" & LF & Node_Format.Generated_Start & LF & Prose &
      Node_Format.Generated_End);

   procedure Notes_Body_Finds_Hand_Written_Content
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Notes_Body
           (Fence ("prose" & LF) & LF & LF & "## Notes" & LF & LF &
            "The thing nobody else knows." & LF & "Second line." & LF & LF) =
         "The thing nobody else knows." & LF & "Second line.",
         "without the heading and the blank lines around it");
   end Notes_Body_Finds_Hand_Written_Content;

   procedure An_Empty_Notes_Section_Risks_Nothing (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Notes_Body
           ("# T" & LF & Node_Format.Generated_End & LF & LF & "## Notes" &
            LF & LF) =
         "",
         "a fresh section");
      Assert
        (Notes_Body ("# T" & LF & Node_Format.Generated_End & LF) = "",
         "no section");
      Assert
        (Notes_Body ("# T" & LF & Node_Format.Generated_End) = "",
         "nothing after the marker");
      Assert (Notes_Body ("# T" & LF & "no fence here" & LF) = "", "no fence");
      Assert
        (Notes_Body
           ("# T" & LF & Node_Format.Generated_End & LF & LF & "## Notes") =
         "",
         "a heading and nothing else");
   end An_Empty_Notes_Section_Risks_Nothing;

   procedure Content_Before_The_Heading_Or_Under_Another_Still_Counts
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Notes_Body
           ("# T" & LF & Node_Format.Generated_End & LF & "loose line" & LF) =
         "loose line",
         "before any heading");
      Assert
        (Notes_Body
           ("# T" & LF & Node_Format.Generated_End & LF & LF & "## Other" &
            LF & "kept" & LF) =
         "## Other" & LF & "kept",
         "a differently worded heading");
      Assert
        (Notes_Body
           ("# T" & LF & Node_Format.Generated_End & LF & LF &
            "## Notes and more" & LF & "x" & LF) =
         "## Notes and more" & LF & "x",
         "a longer heading is content");
   end Content_Before_The_Heading_Or_Under_Another_Still_Counts;

   procedure A_Written_Node_Round_Trips_Through_Its_Readers
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Mine : Note := Base_Note;
   begin
      Mine.Tail := To_Unbounded_String (LF & "## Notes" & LF & "keep this");
      declare
         Written : constant String := Image (Mine);
      begin
         Assert (Notes_Body (Written) = "keep this", "the notes come back");
         Assert
           (To_String (Node_Format.Split (Written).Tail) =
            Node_Format.Generated_End & LF & LF & "## Notes" & LF &
            "keep this" & LF,
            "and so does the tail");
         Assert
           (Stale (Written)'Length > Written'Length - 1
            and then Has (Stale (Written), "stale: true"),
            "it can be flagged stale");
      end;
   end A_Written_Node_Round_Trips_Through_Its_Readers;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Emit");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Title_Is_Sanitized_Only_Where_It_Must_Be'Access,
         "A title is sanitized only where it must be");
      Register_Routine
        (T, A_Directive_Is_Found_Whole'Access, "A directive is found whole");
      Register_Routine
        (T, Every_Directive_Returned_Parses_Again'Access,
         "Every directive returned parses again");
      Register_Routine
        (T, A_Comment_That_Is_Not_A_Directive_Is_Prose'Access,
         "A comment that is not a directive is prose");
      Register_Routine
        (T, Odd_Comment_Shapes_Do_Not_Break_The_Scan'Access,
         "Odd comment shapes do not break the scan");
      Register_Routine
        (T, A_Section_Stops_At_The_Next_Heading_Or_The_Fence'Access,
         "A section stops at the next heading or the fence");
      Register_Routine
        (T, A_Missing_Heading_Is_Not_Found'Access,
         "A missing heading is not found");
      Register_Routine
        (T, A_Quoted_Directive_Outside_The_Section_Is_Not_Found'Access,
         "A quoted directive outside the section is not found");
      Register_Routine
        (T, A_Span_Parses_With_L_Prefixes'Access,
         "A span parses, with L prefixes");
      Register_Routine
        (T, A_Malformed_Span_Is_Rejected'Access,
         "A malformed span is rejected");
      Register_Routine
        (T, A_Three_Bound_Range_Reads_First_To_Last'Access,
         "A three-bound range reads first to last");
      Register_Routine
        (T, A_Huge_Bound_Is_Clamped_And_Reads_As_Out_Of_Range'Access,
         "A huge bound is clamped and reads as out of range");
      Register_Routine
        (T, The_Caps_Differ_By_Kind'Access, "The caps differ by kind");
      Register_Routine
        (T, A_Span_Must_Be_Claimed_And_Fit_The_File'Access,
         "A span must be claimed and fit the file");
      Register_Routine
        (T, A_Crux_Block_Is_The_Fence_The_Slice_And_A_Provenance_Line'Access,
         "A crux block is the fence, the slice and a provenance line");
      Register_Routine
        (T, Substitution_Replaces_The_Whole_Line'Access,
         "Substitution replaces the whole line");
      Register_Routine
        (T, A_Grounding_Disappears_And_One_In_Prose_Is_Cut_Out'Access,
         "A grounding disappears and one in prose is cut out");
      Register_Routine
        (T, Blank_Edges_Are_Trimmed'Access, "Blank edges are trimmed");
      Register_Routine
        (T, A_Summary_Is_Escaped_For_A_Quoted_Scalar'Access,
         "A summary is escaped for a quoted scalar");
      Register_Routine
        (T, A_Fresh_Node_Gets_An_Empty_Notes_Section'Access,
         "A fresh node gets an empty Notes section");
      Register_Routine
        (T, A_Title_With_A_Quote_And_A_Newline_Cannot_Hijack_A_Field'Access,
         "A title with a quote and a newline cannot hijack a field");
      Register_Routine
        (T, Every_Scalar_Field_Comes_Before_The_Sources_List'Access,
         "Every scalar field comes before the sources list");
      Register_Routine
        (T, Sources_List_Paths_Below_The_Threshold_And_Roll_Up_At_It'Access,
         "Sources list paths below the threshold and roll up at it");
      Register_Routine
        (T, An_Existing_Tail_Is_Reemitted'Access,
         "An existing tail is re-emitted");
      Register_Routine
        (T, An_Absent_Commit_Omits_The_Field'Access,
         "An absent commit omits the field");
      Register_Routine
        (T, Crux_And_Grounded_Fields_Appear_Only_When_There_Are_Any'Access,
         "Crux and grounded_in fields appear only when there are any");
      Register_Routine
        (T, A_Recovered_Body_Written_Back_Produces_The_Same_Bytes'Access,
         "A recovered body written back produces the same bytes");
      Register_Routine
        (T, Set_Stale_Rewrites_One_Line'Access, "Set_Stale rewrites one line");
      Register_Routine
        (T, Set_Stale_Handles_Crlf'Access, "Set_Stale handles CRLF");
      Register_Routine
        (T, An_Already_Stale_Node_Reports_No_Change'Access,
         "An already stale node reports no change");
      Register_Routine
        (T, A_Node_With_No_Stale_Field_Gains_One'Access,
         "A node with no stale field gains one");
      Register_Routine
        (T, A_File_With_No_Frontmatter_Is_Left_Alone'Access,
         "A file with no frontmatter is left alone");
      Register_Routine
        (T, Only_The_Frontmatters_Stale_Line_Is_Touched'Access,
         "Only the frontmatter's stale line is touched");
      Register_Routine
        (T, Fenced_Text_Is_A_Toggle_Not_A_Parser'Access,
         "Fenced_Text is a toggle, not a parser");
      Register_Routine
        (T, Notes_Body_Finds_Hand_Written_Content'Access,
         "Notes_Body finds hand-written content");
      Register_Routine
        (T, An_Empty_Notes_Section_Risks_Nothing'Access,
         "An empty Notes section risks nothing");
      Register_Routine
        (T, Content_Before_The_Heading_Or_Under_Another_Still_Counts'Access,
         "Content before the heading or under another still counts");
      Register_Routine
        (T, A_Written_Node_Round_Trips_Through_Its_Readers'Access,
         "A written node round-trips through its readers");
   end Register_Tests;

end Synapse.Core.Emit.Tests;
