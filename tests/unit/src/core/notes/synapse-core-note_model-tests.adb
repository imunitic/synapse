with Ada.Characters.Latin_1;
with Ada.Containers;
with Ada.Strings.Fixed;

with AUnit.Assertions;

with Interfaces;

with Synapse.Core.JSON_Logic;

package body Synapse.Core.Note_Model.Tests is

   use AUnit.Assertions;
   use JSON;
   use type Interfaces.Unsigned_64;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Ada.Characters.Latin_1.LF;
   CR : constant Character := Ada.Characters.Latin_1.CR;

   function Fm (Lines : String) return String
   is ("---" & LF & Lines & "---" & LF);

   --  A field as one short word: `string:x`, `int:5`, `bool:true`,
   --  `list:a|b`, `invalid` or `missing`.
   function Describe (Note, Name : String) return String is
      Found : constant Lookup := Lookup_Field (Note, Name);
   begin
      if not Found.Found then
         return "missing";
      end if;
      case Found.Value.Kind is
         when String_Field =>
            return "string:" & To_String (Found.Value.Text);

         when Integer_Field =>
            return "int:" & Long_Long_Integer'Image (Found.Value.Number);

         when Boolean_Field =>
            return "bool:" & Boolean'Image (Found.Value.Flag);

         when List_Field =>
            declare
               Text : Unbounded_String := To_Unbounded_String ("list:");
            begin
               for I in 1 .. Natural (Found.Value.Items.Length) loop
                  if I > 1 then
                     Append (Text, "|");
                  end if;
                  Append (Text, Found.Value.Items (I));
               end loop;
               return To_String (Text);
            end;

         when Invalid_Field =>
            return "invalid";
      end case;
   end Describe;

   procedure Field_Is (Lines, Name, Want : String) is
      Got : constant String := Describe (Fm (Lines), Name);
   begin
      Assert (Got = Want, Lines & " -> '" & Got & "', wanted '" & Want & "'");
   end Field_Is;

   --  JSON text with ' standing for ".
   function J (Text : String) return Value is
      Quoted : String := Text;
   begin
      for C of Quoted loop
         if C = ''' then
            C := '"';
         end if;
      end loop;
      declare
         Parsed : constant Parse_Result := Parse (Quoted);
      begin
         Assert (Parsed.Ok, "JSON parses: " & Text);
         return Parsed.Item;
      end;
   end J;

   function Tree
     (Note : String; Ctx : Context := (others => <>);
      Path : String := "x.md") return Value
   is (Data_Tree (Path, Note, Ctx));

   function Holds (Rule : String; Data : Value) return Boolean
   is (JSON_Logic.Truthy
         (JSON_Logic.Evaluate (J (Rule), (Data => Data, others => <>))));

   ---------------------------------------------------------------------------
   --  Typed fields
   ---------------------------------------------------------------------------

   procedure Block_Style_Lists_Keep_Empty_Apart_From_Missing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Listed : constant Lookup :=
        Lookup_Field
          ("---" & LF & "tags:" & LF & "  - synapse" & LF
           & "  - architecture" & LF & "---" & LF, "tags");
   begin
      Assert (Listed.Found and then Listed.Value.Kind = List_Field
              and then Listed.Value.Items.Length = 2, "two items");
      Field_Is ("tags:" & LF, "tags", "list:");
      Field_Is ("title: x" & LF, "tags", "missing");
   end Block_Style_Lists_Keep_Empty_Apart_From_Missing;

   procedure Scalars_Are_Typed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Field_Is ("a: hello" & LF, "a", "string:hello");
      Field_Is ("a: ""hello world""" & LF, "a", "string:hello world");
      Field_Is ("a: 'hello'" & LF, "a", "string:hello");
      Field_Is ("a: ""5""" & LF, "a", "string:5");
      Field_Is ("a: ""true""" & LF, "a", "string:true");
      Field_Is ("a: """"" & LF, "a", "string:");
      Field_Is ("a: 5" & LF, "a", "int: 5");
      Field_Is ("a: -5" & LF, "a", "int:-5");
      Field_Is ("a: 007" & LF, "a", "int: 7");
      Field_Is ("a: 99999999999999999999" & LF, "a",
                "string:99999999999999999999");
      Field_Is ("a: 1.5" & LF, "a", "string:1.5");
      Field_Is ("a: true" & LF, "a", "bool:TRUE");
      Field_Is ("a: false" & LF, "a", "bool:FALSE");
      Field_Is ("a: True" & LF, "a", "string:True");
      Field_Is ("a: null" & LF, "a", "string:null");
      Field_Is ("a: 2026-09-06T21:29:16Z" & LF, "a",
                "string:2026-09-06T21:29:16Z");
      Field_Is ("a: has: colon" & LF, "a", "string:has: colon");
      Field_Is ("a:value" & LF, "a", "string:value");
      Field_Is ("a:" & LF & "b: 1" & LF, "a", "list:");
   end Scalars_Are_Typed;

   procedure Comments_And_Blanks_Around_A_Value_Are_Dropped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Field_Is ("a: x # why" & LF, "a", "string:x");
      Field_Is ("a: 5 # five" & LF, "a", "int: 5");
      Field_Is ("a:    spaced    " & LF, "a", "string:spaced");
      Field_Is ("a: ""x # not a comment""" & LF, "a",
                "string:x # not a comment");
      Field_Is ("a: [x, y] # list" & LF, "a", "list:x|y");
      Field_Is ("a: # only a comment" & LF & "  - item" & LF, "a",
                "list:item");
   end Comments_And_Blanks_Around_A_Value_Are_Dropped;

   procedure Flow_Lists_Split_Outside_Quotes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Field_Is ("a: [x, y, z]" & LF, "a", "list:x|y|z");
      Field_Is ("a: [x,y]" & LF, "a", "list:x|y");
      Field_Is ("a: []" & LF, "a", "list:");
      Field_Is ("a: [ ]" & LF, "a", "list:");
      Field_Is ("a: [""x, y"", z]" & LF, "a", "list:x, y|z");
      Field_Is ("a: ['x', ""y""]" & LF, "a", "list:x|y");
      Field_Is ("a: [x, ]" & LF, "a", "list:x|");
      Field_Is ("a: [,]" & LF, "a", "list:|");
      Field_Is ("a: [5, true]" & LF, "a", "list:5|true");
      Field_Is ("a: [x" & LF, "a", "invalid");
      Field_Is ("a: [" & LF, "a", "invalid");
      Field_Is ("a: [x, ""y]" & LF, "a", "list:x|""y");
   end Flow_Lists_Split_Outside_Quotes;

   procedure Block_Lists_Read_Their_Items (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Field_Is ("a:" & LF & "  - x" & LF & "  - y" & LF & "b: 1" & LF, "a",
                "list:x|y");
      Field_Is ("a:" & LF & "  - ""x y""" & LF & "  - 'z'" & LF, "a",
                "list:x y|z");
      Field_Is ("a:" & LF & "  - x # note" & LF, "a", "list:x");
      Field_Is ("a:" & LF & LF & "  - x" & LF & "   " & LF & "  - y" & LF,
                "a", "list:x|y");
      Field_Is ("a:" & LF & "    -   deep   " & LF, "a", "list:deep");
      Field_Is ("a:" & LF & "  - " & LF, "a", "invalid");  --  trimmed to `-`
      Field_Is ("a:" & LF & "  - ''" & LF, "a", "list:");
      Field_Is ("a:" & LF & "  -x" & LF, "a", "invalid");
      Field_Is ("a:" & LF & "  - path: x" & LF & "    hash: y" & LF, "a",
                "invalid");
      Field_Is ("a:" & LF & "  - x" & LF & "note" & LF, "a", "list:x");
      Field_Is ("a:" & LF & "  - x" & LF & "  note" & LF, "a", "invalid");
      Field_Is ("a:" & LF & "  - x" & LF & "b:" & LF & "  - y" & LF, "b",
                "list:y");
   end Block_Lists_Read_Their_Items;

   procedure Invalid_Shapes_Are_Reported (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Field_Is ("a: ""open" & LF, "a", "invalid");
      Field_Is ("a: 'open" & LF, "a", "invalid");
      Field_Is ("a: """ & LF, "a", "invalid");
      Field_Is ("a: ""closed with other'" & LF, "a", "invalid");
   end Invalid_Shapes_Are_Reported;

   procedure Keys_Are_Whole_And_Top_Level (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Field_Is ("title: x" & LF, "title", "string:x");
      Field_Is ("subtitle: x" & LF, "title", "missing");
      Field_Is ("titled: x" & LF, "title", "missing");
      Field_Is ("  title: x" & LF, "title", "missing");
      Field_Is ("a:" & LF & "  title: x" & LF, "title", "missing");
      Field_Is ("# title: x" & LF, "title", "missing");
      Field_Is ("#title: x" & LF, "title", "missing");
      Field_Is ("title : x" & LF, "title", "string:x");
      Field_Is ("no colon here" & LF & "title: x" & LF, "title", "string:x");
      Field_Is ("TITLE: x" & LF, "title", "missing");
   end Keys_Are_Whole_And_Top_Level;

   procedure Duplicates_Are_Reported_And_The_First_Wins
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Note   : constant String :=
        Fm ("a: first" & LF & "b: 1" & LF & "a: second" & LF);
      Found  : constant Lookup := Lookup_Field (Note, "a");
      Single : constant Lookup := Lookup_Field (Note, "b");
   begin
      Assert (Found.Found and then Found.Duplicate, "duplicate");
      Assert (To_String (Found.Value.Text) = "first", "first wins");
      Assert (Single.Found and then not Single.Duplicate, "single");
      Assert (Describe (Note, "a") = "string:first", "described");
   end Duplicates_Are_Reported_And_The_First_Wins;

   procedure A_Note_Without_Frontmatter_Has_No_Fields
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Describe ("# Title" & LF, "a") = "missing", "no block");
      Assert (Describe ("---" & LF & "a: 1" & LF, "a") = "missing",
              "an unclosed block");
      Assert (Describe ("", "a") = "missing", "empty");
      Assert (Describe ("a: 1" & LF, "a") = "missing", "bare field");
      Assert (Describe ("---" & LF & "---" & LF & "a: 1" & LF, "a")
              = "missing", "the field is in the body");
   end A_Note_Without_Frontmatter_Has_No_Fields;

   procedure Line_Endings_Do_Not_Matter (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Note : constant String :=
        "---" & CR & LF & "a: x" & CR & LF & "t: [p, q]" & CR & LF
        & "l:" & CR & LF & "  - m" & CR & LF & "n: 3" & CR & LF
        & "---" & CR & LF & "body" & CR & LF;
   begin
      Assert (Describe (Note, "a") = "string:x", "string");
      Assert (Describe (Note, "t") = "list:p|q", "flow");
      Assert (Describe (Note, "l") = "list:m", "block");
      Assert (Describe (Note, "n") = "int: 3", "integer");
   end Line_Endings_Do_Not_Matter;

   procedure Types_And_Equality_Follow_The_Schema_Names
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      function Value_Of (Name : String) return Field_Value
      is (Lookup_Field
            (Fm ("s: x" & LF & "i: 4" & LF & "b: true" & LF & "l: [x]" & LF
                 & "bad: ""open" & LF & "s2: x" & LF & "i2: 4" & LF
                 & "l2: [x]" & LF & "l3: [y]" & LF & "bad2: [" & LF),
             Name).Value);

      S : constant Field_Value := Value_Of ("s");
      I : constant Field_Value := Value_Of ("i");
      B : constant Field_Value := Value_Of ("b");
      L : constant Field_Value := Value_Of ("l");
      V : constant Field_Value := Value_Of ("bad");
   begin
      Assert (Has_Type (S, "string") and then Has_Type (S, "timestamp"),
              "a string is a string and a timestamp");
      Assert (not Has_Type (S, "list") and then not Has_Type (S, "integer")
              and then not Has_Type (S, "boolean"), "and nothing else");
      Assert (Has_Type (I, "integer") and then not Has_Type (I, "string"),
              "integer");
      Assert (Has_Type (B, "boolean") and then not Has_Type (B, "integer"),
              "boolean");
      Assert (Has_Type (L, "list") and then not Has_Type (L, "string"),
              "list");
      Assert (Has_Type (S, "any") and then Has_Type (I, "any")
              and then Has_Type (B, "any") and then Has_Type (L, "any")
              and then Has_Type (V, "any"), "any holds every value");
      Assert (not Has_Type (S, "float") and then not Has_Type (V, "string"),
              "an unknown type, an invalid value");
      Assert (not Has_Type (S, ""), "empty type name");

      Assert (Values_Equal (S, Value_Of ("s2")), "equal strings");
      Assert (Values_Equal (I, Value_Of ("i2")), "equal integers");
      Assert (Values_Equal (L, Value_Of ("l2")), "equal lists");
      Assert (not Values_Equal (L, Value_Of ("l3")), "different lists");
      Assert (not Values_Equal (S, I), "different kinds");
      Assert (not Values_Equal (S, B), "string and boolean");
      Assert (Values_Equal (V, Value_Of ("bad2")), "two invalid values");
      Assert (not Values_Equal (V, S), "invalid and string");
   end Types_And_Equality_Follow_The_Schema_Names;

   ---------------------------------------------------------------------------
   --  Field order
   ---------------------------------------------------------------------------

   procedure Field_Order_Follows_The_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Note      : constant String :=
        Fm ("title: x" & LF & "tags:" & LF & "  - a" & LF & "# note" & LF
            & "status: TODO" & LF & "title: again" & LF & "no colon" & LF
            & "last: 1" & LF);
      Positions : constant Position_Vectors.Vector := Field_Positions (Note);

      function Key_At (Offset : Natural) return String is
         Stop : Natural := Note'First + Offset;
      begin
         while Note (Stop) /= ':' loop
            Stop := Stop + 1;
         end loop;
         return Note (Note'First + Offset .. Stop - 1);
      end Key_At;
   begin
      Assert (Positions.Length = 4, "four distinct keys");
      Assert (To_String (Positions (1).Key) = "title", "title first");
      Assert (To_String (Positions (2).Key) = "tags", "then tags");
      Assert (To_String (Positions (3).Key) = "status", "then status");
      Assert (To_String (Positions (4).Key) = "last", "then last");
      for P of Positions loop
         Assert (Key_At (P.Line_Start) = To_String (P.Key),
                 "the offset is the key's line: " & To_String (P.Key));
      end loop;
      Assert (Positions (1).Line_Start = 4, "after the opening fence");
      Assert (Field_Positions ("# no frontmatter").Is_Empty, "none");
      Assert (Field_Positions ("---" & LF & "a: 1" & LF).Is_Empty,
              "unclosed");
   end Field_Order_Follows_The_File;

   ---------------------------------------------------------------------------
   --  Headings
   ---------------------------------------------------------------------------

   procedure Headings_Carry_Their_Content_Ranges (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        "# One" & LF & "intro" & LF & "## Two" & LF & "text" & LF
        & "### Three" & LF & "deep" & LF & "## Four" & LF & "more" & LF
        & "# Five" & LF & "end" & LF;
      H    : constant Heading_Array := Collect_Headings (Text);

      function Content (I : Positive) return String
      is (Text (Text'First + H (I).Content_Start
                .. Text'First + H (I).Content_End - 1));
   begin
      Assert (H'Length = 5, "five headings");
      Assert (To_String (H (1).Title) = "One" and then H (1).Level = 1,
              "first");
      Assert (To_String (H (3).Title) = "Three" and then H (3).Level = 3,
              "third");
      Assert (H (1).Line_Start = 0, "first line");
      Assert (Content (1) = "intro" & LF & "## Two" & LF & "text" & LF
              & "### Three" & LF & "deep" & LF & "## Four" & LF & "more" & LF,
              "level one runs to the next level one");
      Assert (Content (2) = "text" & LF & "### Three" & LF & "deep" & LF,
              "level two runs to the next level two");
      Assert (Content (3) = "deep" & LF, "level three runs to a shallower");
      Assert (Content (4) = "more" & LF, "level two before a level one");
      Assert (Content (5) = "end" & LF, "the last runs to the end");
   end Headings_Carry_Their_Content_Ranges;

   procedure Headings_Inside_Fences_And_Indented_Are_Not_Headings
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        "# Real" & LF & "```" & LF & "# code" & LF & "```" & LF & "~~~"
        & LF & "## tilde code" & LF & "~~~" & LF & "  # indented" & LF
        & "#nospace" & LF & "####### seven" & LF & "## After" & LF;
      H    : constant Heading_Array := Collect_Headings (Text);
   begin
      Assert (H'Length = 2, "two headings");
      Assert (To_String (H (1).Title) = "Real", "real");
      Assert (To_String (H (2).Title) = "After", "after");
      Assert (Collect_Headings ("")'Length = 0, "empty text");
      Assert (Collect_Headings ("no headings" & LF)'Length = 0, "none");
      Assert (Collect_Headings ("```" & LF & "# open fence")'Length = 0,
              "an unclosed fence hides the rest");
   end Headings_Inside_Fences_And_Indented_Are_Not_Headings;

   procedure Heading_Edge_Cases (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Crlf : constant Heading_Array :=
        Collect_Headings ("# A" & CR & LF & "text" & CR & LF & "## B" & CR);
      Last : constant Heading_Array := Collect_Headings ("# Only");
      Many : constant Heading_Array :=
        Collect_Headings ("# " & LF & "# x # y  " & LF);
   begin
      Assert (Crlf'Length = 2, "CRLF headings");
      Assert (To_String (Crlf (1).Title) = "A", "CR is not in the title");
      Assert (To_String (Crlf (2).Title) = "B", "a bare CR at the end");
      Assert (Last'Length = 1 and then Last (1).Content_Start = 6
              and then Last (1).Content_End = 6, "no line ending, no content");
      Assert (Many'Length = 2 and then To_String (Many (1).Title) = "",
              "an empty title");
      Assert (To_String (Many (2).Title) = "x # y", "trimmed, inner hash");
   end Heading_Edge_Cases;

   ---------------------------------------------------------------------------
   --  JSON views
   ---------------------------------------------------------------------------

   procedure Frontmatter_Becomes_Strings_And_Lists
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Check (Lines, Want : String) is
         Got : constant String := To_String (Frontmatter_As_JSON (Fm (Lines)));
      begin
         Assert (Got = To_String (J (Want)),
                 Lines & " -> " & Got & ", wanted " & To_String (J (Want)));
      end Check;
   begin
      Check ("title: X" & LF, "{'title': 'X'}");
      Check ("title: ""X y""" & LF & "n: 2" & LF, "{'title':'X y','n':'2'}");
      Check ("tags: [a, 'b c', d]" & LF, "{'tags': ['a', 'b c', 'd']}");
      Check ("tags: []" & LF, "{'tags': []}");
      Check ("tags:" & LF & "  - a" & LF & "  - 'b'" & LF & "k: v" & LF,
             "{'tags': ['a', 'b'], 'k': 'v'}");
      Check ("tags:" & LF, "{'tags': []}");
      Check ("tags:" & LF & "k: v" & LF, "{'tags': [], 'k': 'v'}");
      Check ("tags:" & LF & LF & "  - a" & LF, "{'tags': ['a']}");
      Check ("a: 1" & LF & "a: 2" & LF, "{'a': '2'}");
      Assert (To_String (Frontmatter_As_JSON (Fm ("a: [x, 'y, z']" & LF)))
              = "{""a"":[""x"",""'y"",""z'""]}", "commas split inside quotes");
      Check ("a: x # kept" & LF, "{'a': 'x # kept'}");
      Check ("a: true" & LF, "{'a': 'true'}");
      Check ("# c: 1" & LF, "{'# c': '1'}");
      Check ("  nested: 1" & LF & "plain" & LF & ": nokey" & LF, "{}");
      Check ("", "{}");
      Check ("tags:" & LF & "  - k: v" & LF, "{'tags': ['k: v']}");
   end Frontmatter_Becomes_Strings_And_Lists;

   procedure Frontmatter_JSON_Handles_Line_Endings_And_Absence
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (To_String
           (Frontmatter_As_JSON
              ("---" & CR & LF & "a: x" & CR & LF & "t:" & CR & LF & "  - y"
               & CR & LF & "---" & CR & LF))
         = To_String (J ("{'a': 'x', 't': ['y']}")), "CRLF");
      Assert (To_String (Frontmatter_As_JSON ("# Just a body" & LF)) = "{}",
              "no frontmatter");
      Assert (To_String (Frontmatter_As_JSON ("---" & LF & "a: 1" & LF))
              = "{}", "an unclosed block is not frontmatter");
   end Frontmatter_JSON_Handles_Line_Endings_And_Absence;

   procedure Vocabulary_Lines_Contribute_Their_Value
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Check (Content, Want : String) is
      begin
         Assert (To_String (Vocabulary_Items (Content))
                 = To_String (J (Want)), Content);
      end Check;
   begin
      Check ("synapse" & LF & "vault-infra" & LF & "# a comment" & LF & LF
             & "architecture" & LF,
             "['synapse', 'vault-infra', 'architecture']");
      Check ("synapse=sb" & LF & "eon = eon" & LF, "['sb', 'eon']");
      Check ("a # trailing" & LF & "b=c # trailing" & LF, "['a', 'c']");
      Check ("a" & CR & LF & "b" & CR & LF, "['a', 'b']");
      Check ("  spaced  " & LF & Character'Val (9) & "x" & LF,
             "['spaced', 'x']");
      Check ("", "[]");
      Check (LF & LF, "[]");
      Check ("k=" & LF, "['']");
      Check ("=v" & LF, "['v']");
      Check ("a=b=c" & LF, "['b=c']");
      Check ("no newline", "['no newline']");
   end Vocabulary_Lines_Contribute_Their_Value;

   ---------------------------------------------------------------------------
   --  The data tree
   ---------------------------------------------------------------------------

   procedure The_Tree_Carries_Path_Frontmatter_And_Body
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Note : constant String :=
        Fm ("title: X" & LF & "status: REVIEW" & LF)
        & "# X" & LF & LF & "## Summary" & LF & "Some prose." & LF & LF
        & "## Notes" & LF & "More prose." & LF;
      Data : constant Value :=
        Tree (Note, Path => "tasks/synapse/X.md");
      Body_Part : constant Value := Member_Value (Data, "body");
      Names     : constant Value := Member_Value (Body_Part, "section_names");
   begin
      Assert (As_String (Member_Value (Data, "path")) = "tasks/synapse/X.md",
              "path");
      Assert (As_String (Member_Value (Member_Value (Data, "filename"),
                                       "stem")) = "X", "stem");
      Assert (As_String (Member_Value (Member_Value (Data, "frontmatter"),
                                       "status")) = "REVIEW", "frontmatter");
      declare
         Prose : constant String :=
           As_String (Member_Value (Body_Part, "prose"));
      begin
         Assert (Prose (Prose'First .. Prose'First + 3) = "# X" & LF,
                 "the prose starts at the body");
         Assert (Ada.Strings.Fixed.Index (Prose, "title: X") = 0,
                 "and has no frontmatter");
      end;
      Assert (Length (Names) = 3, "three headings");
      Assert (As_String (Element (Names, 1)) = "X", "first");
      Assert (As_String (Element (Names, 2)) = "Summary", "second");
      Assert (As_String (Element (Names, 3)) = "Notes", "third");
   end The_Tree_Carries_Path_Frontmatter_And_Body;

   procedure A_Note_Without_Frontmatter_Is_All_Body
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Note : constant String :=
        "# Just a heading" & LF & LF & "No frontmatter here at all." & LF;
      Data : constant Value := Tree (Note, Path => "notes/legacy.md");
      Body_Part : constant Value := Member_Value (Data, "body");
   begin
      Assert (As_String (Member_Value (Body_Part, "prose")) = Note,
              "all of it");
      Assert (Length (Member_Value (Body_Part, "section_names")) = 1,
              "one heading");
      Assert (Length (Member_Value (Data, "frontmatter")) = 0,
              "empty frontmatter object");
   end A_Note_Without_Frontmatter_Is_All_Body;

   procedure The_Tree_Evaluates_Through_JsonLogic
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Data : constant Value :=
        Tree (Fm ("title: X" & LF & "status: REVIEW" & LF)
              & "# X" & LF & LF & "## Notes" & LF & "Done." & LF);
   begin
      Assert
        (Holds
           ("{'or': [{'!=': [{'var': 'frontmatter.status'}, 'REVIEW']},"
            & " {'in': ['Notes', {'var': 'body.section_names'}]}]}", Data),
         "status and sections");
      Assert (Holds ("{'==': [{'var': 'filename.stem'}, 'x']}", Data),
              "stem");
      Assert (not Holds ("{'in': ['Missing', {'var': 'body.section_names'}]}",
                         Data), "absent section");
   end The_Tree_Evaluates_Through_JsonLogic;

   procedure Creating_Means_Create_Or_Migration
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Note : constant String := Fm ("title: X" & LF) & "# X" & LF;

      function Creates (M : Mode) return Boolean
      is (As_Boolean
            (Member_Value (Tree (Note, (Mode => M, others => <>)),
                           "is_create")));
   begin
      Assert (Creates (Create), "create");
      Assert (Creates (Migration), "migration");
      Assert (not Creates (Update), "update");
   end Creating_Means_Create_Or_Migration;

   procedure Identity_Is_Unknown_On_Update_Not_False
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Note : constant String := Fm ("title: X" & LF) & "# X" & LF;

      function Unique
        (M : Mode; Duplicate : Boolean) return Value
      is (Member_Value
            (Tree (Note, (Mode          => M,
                          Has_Duplicate => Duplicate,
                          others        => <>)),
             "id_is_unique"));
   begin
      Assert (As_Boolean (Unique (Create, False)), "unique on create");
      Assert (not As_Boolean (Unique (Create, True)), "duplicate on create");
      Assert (As_Boolean (Unique (Migration, False)), "unique on migration");
      Assert (not As_Boolean (Unique (Migration, True)),
              "duplicate on migration");
      Assert (Kind_Of (Unique (Update, False)) = JSON_Null,
              "not computed on update");
      Assert (Kind_Of (Unique (Update, True)) = JSON_Null,
              "not computed, whatever was found");
   end Identity_Is_Unknown_On_Update_Not_False;

   procedure Epochs_Come_From_Real_Timestamps (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Epoch (Lines, Name : String) return Value
      is (Member_Value (Tree (Fm (Lines) & "# X" & LF), Name));

      Good : constant String :=
        "title: X" & LF & "created: ""2026-09-07T15:00:00Z""" & LF
        & "updated: ""2026-09-07T15:05:00Z""" & LF;
   begin
      Assert (As_Integer (Epoch (Good, "created_epoch")) = 1_788_793_200,
              "created");
      Assert (As_Integer (Epoch (Good, "updated_epoch"))
              = As_Integer (Epoch (Good, "created_epoch")) + 300, "updated");
      Assert (Kind_Of (Epoch ("title: X" & LF, "created_epoch")) = JSON_Null,
              "missing");
      Assert (Kind_Of (Epoch ("created: not-a-timestamp" & LF,
                              "created_epoch")) = JSON_Null, "malformed");
      Assert (Kind_Of (Epoch ("created: 5" & LF, "created_epoch"))
              = JSON_Null, "not a string");
      Assert (Kind_Of (Epoch ("created: [2026-09-07T15:00:00Z]" & LF,
                              "created_epoch")) = JSON_Null, "a list");
      Assert (Kind_Of (Epoch ("created: ""2026-09-07T15:00:00""" & LF,
                              "created_epoch")) = JSON_Null, "no zone");
      Assert (Holds ("{'<=': [{'var': 'created_epoch'},"
                     & " {'var': 'updated_epoch'}]}",
                     Tree (Fm (Good) & "# X" & LF)),
              "not_before is a plain comparison");
   end Epochs_Come_From_Real_Timestamps;

   procedure Vocabularies_Are_Keyed_By_Stem (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Ctx  : Context;
      Note : constant String :=
        Fm ("title: X" & LF & "tags: [synapse, vault-infra]" & LF)
        & "# X" & LF;
   begin
      Assert (Length (Member_Value (Tree (Note, Ctx), "vocabularies")) = 0,
              "none supplied");

      Ctx.Vocabularies.Append
        (Vocabulary_Source'
           (Stem    => To_Unbounded_String ("synapse-tag-vocabulary"),
          Content => To_Unbounded_String
            ("synapse" & LF & "vault-infra" & LF & "# a comment" & LF & LF
             & "architecture" & LF)));
      Ctx.Vocabularies.Append
        (Vocabulary_Source'
           (Stem    => To_Unbounded_String ("synapse-projects"),
          Content =>
            To_Unbounded_String ("synapse=sb" & LF & "eon=eon" & LF)));

      declare
         Data   : constant Value := Tree (Note, Ctx);
         Vocabs : constant Value := Member_Value (Data, "vocabularies");
      begin
         Assert (To_String (Member_Value (Vocabs, "synapse-tag-vocabulary"))
                 = To_String (J ("['synapse','vault-infra','architecture']")),
                 "plain lines");
         Assert (To_String (Member_Value (Vocabs, "synapse-projects"))
                 = To_String (J ("['sb','eon']")), "key=value lines");
         Assert
           (Holds
              ("{'all': [{'var': 'frontmatter.tags'},"
               & " {'in': [{'var': ''},"
               & " {'var': 'vocabularies.synapse-tag-vocabulary'}]}]}",
               Data),
            "every tag is in the vocabulary");
         Assert
           (not Holds
              ("{'all': [{'var': 'frontmatter.tags'},"
               & " {'in': [{'var': ''},"
               & " {'var': 'vocabularies.synapse-projects'}]}]}",
               Data),
            "and not in the other file");
      end;
   end Vocabularies_Are_Keyed_By_Stem;

   procedure Text_That_Is_Not_UTF8_Still_Makes_A_Tree
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bad  : constant String := "caf" & Character'Val (16#E9#);
      Data : constant Value :=
        Tree (Fm ("title: " & Bad & LF) & "# " & Bad & LF);
   begin
      Assert (As_String (Member_Value (Member_Value (Data, "frontmatter"),
                                       "title"))
              = "caf" & Character'Val (16#EF#) & Character'Val (16#BF#)
                & Character'Val (16#BD#), "replaced by U+FFFD");
      Assert (Length (Member_Value (Member_Value (Data, "body"),
                                    "section_names")) = 1, "heading found");
   end Text_That_Is_Not_UTF8_Still_Makes_A_Tree;

   ---------------------------------------------------------------------------
   --  Properties
   ---------------------------------------------------------------------------

   procedure Random_Notes_Never_Raise (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      State : Interfaces.Unsigned_64 := 16#D1B5_4A32_D192_ED03#;

      function Next (Bound : Positive) return Natural is
      begin
         State :=
           State * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
         return
           Natural ((State / 65_536) mod Interfaces.Unsigned_64 (Bound));
      end Next;

      function Piece (N : Natural) return String
      is (case N is
            when 0 => "---" & LF,
            when 1 => "a: ",
            when 2 => "[x, ",
            when 3 => "]",
            when 4 => """q",
            when 5 => "'",
            when 6 => ": ",
            when 7 => " # c",
            when 8 => "  - ",
            when 9 => "- ",
            when 10 => "# ",
            when 11 => "```" & LF,
            when 12 => "~~~" & LF,
            when 13 => "" & LF,
            when 14 => CR & LF,
            when 15 => "tags:",
            when 16 => "12",
            when 17 => "true",
            when 18 => "\",
            when 19 => " ",
            when 20 => "## T",
            when others => "" & Character'Val (16#E9#));
   begin
      for Round in 1 .. 3_000 loop
         declare
            Text : Unbounded_String;
         begin
            for K in 1 .. Next (30) loop
               Append (Text, Piece (Next (22)));
            end loop;
            declare
               Note : constant String := To_String (Text);
               Look : constant Lookup := Lookup_Field (Note, "a");
               Heads : constant Heading_Array := Collect_Headings (Note);
               Tree_Value : constant Value :=
                 Data_Tree ("p/x.md", Note, (others => <>));
               Fields : constant Position_Vectors.Vector :=
                 Field_Positions (Note);
               pragma Unreferenced (Look, Tree_Value);
            begin
               for I in Heads'Range loop
                  Assert (Heads (I).Content_Start <= Heads (I).Content_End
                          and then Heads (I).Content_End <= Note'Length,
                          "ranges stay inside the text");
                  if I > Heads'First then
                     Assert (Heads (I).Line_Start > Heads (I - 1).Line_Start,
                             "headings are in order");
                  end if;
               end loop;
               for I in 1 .. Natural (Fields.Length) loop
                  for J in I + 1 .. Natural (Fields.Length) loop
                     Assert (Fields (I).Key /= Fields (J).Key,
                             "keys are distinct");
                  end loop;
               end loop;
            end;
         exception
            when others =>
               Assert (False, "raised on round" & Round'Image);
         end;
      end loop;
   end Random_Notes_Never_Raise;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Note_Model");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Block_Style_Lists_Keep_Empty_Apart_From_Missing'Access,
         "Block-style lists keep empty apart from missing");
      Register_Routine (T, Scalars_Are_Typed'Access, "Scalars are typed");
      Register_Routine
        (T, Comments_And_Blanks_Around_A_Value_Are_Dropped'Access,
         "Comments and blanks around a value are dropped");
      Register_Routine
        (T, Flow_Lists_Split_Outside_Quotes'Access,
         "Flow lists split outside quotes");
      Register_Routine
        (T, Block_Lists_Read_Their_Items'Access,
         "Block lists read their items");
      Register_Routine
        (T, Invalid_Shapes_Are_Reported'Access,
         "Invalid shapes are reported");
      Register_Routine
        (T, Keys_Are_Whole_And_Top_Level'Access,
         "Keys are whole and top level");
      Register_Routine
        (T, Duplicates_Are_Reported_And_The_First_Wins'Access,
         "Duplicates are reported and the first wins");
      Register_Routine
        (T, A_Note_Without_Frontmatter_Has_No_Fields'Access,
         "A note without frontmatter has no fields");
      Register_Routine
        (T, Line_Endings_Do_Not_Matter'Access, "Line endings do not matter");
      Register_Routine
        (T, Types_And_Equality_Follow_The_Schema_Names'Access,
         "Types and equality follow the schema names");
      Register_Routine
        (T, Field_Order_Follows_The_File'Access,
         "Field order follows the file");
      Register_Routine
        (T, Headings_Carry_Their_Content_Ranges'Access,
         "Headings carry their content ranges");
      Register_Routine
        (T, Headings_Inside_Fences_And_Indented_Are_Not_Headings'Access,
         "Headings inside fences and indented are not headings");
      Register_Routine (T, Heading_Edge_Cases'Access, "Heading edge cases");
      Register_Routine
        (T, Frontmatter_Becomes_Strings_And_Lists'Access,
         "Frontmatter becomes strings and lists");
      Register_Routine
        (T, Frontmatter_JSON_Handles_Line_Endings_And_Absence'Access,
         "Frontmatter JSON handles line endings and absence");
      Register_Routine
        (T, Vocabulary_Lines_Contribute_Their_Value'Access,
         "Vocabulary lines contribute their value");
      Register_Routine
        (T, The_Tree_Carries_Path_Frontmatter_And_Body'Access,
         "The tree carries path, frontmatter and body");
      Register_Routine
        (T, A_Note_Without_Frontmatter_Is_All_Body'Access,
         "A note without frontmatter is all body");
      Register_Routine
        (T, The_Tree_Evaluates_Through_JsonLogic'Access,
         "The tree evaluates through JsonLogic");
      Register_Routine
        (T, Creating_Means_Create_Or_Migration'Access,
         "Creating means create or migration");
      Register_Routine
        (T, Identity_Is_Unknown_On_Update_Not_False'Access,
         "Identity is unknown on update, not false");
      Register_Routine
        (T, Epochs_Come_From_Real_Timestamps'Access,
         "Epochs come from real timestamps");
      Register_Routine
        (T, Vocabularies_Are_Keyed_By_Stem'Access,
         "Vocabularies are keyed by stem");
      Register_Routine
        (T, Text_That_Is_Not_UTF8_Still_Makes_A_Tree'Access,
         "Text that is not UTF-8 still makes a tree");
      Register_Routine
        (T, Random_Notes_Never_Raise'Access, "Random notes never raise");
   end Register_Tests;

end Synapse.Core.Note_Model.Tests;
