with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Interfaces;

with Synapse.Core.Frontmatter.Edit;
with Synapse.Core.UTF8;

package body Synapse.Core.Frontmatter.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Core.Frontmatter.Edit;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);
   HT : constant Character := Character'Val (9);
   Backslash : constant Character := Character'Val (92);

   Hash : constant String := "1111111111111111111111111111111111111111";

   Sample : constant String :=
     "---" & LF
     & "title: ""State machine""" & LF
     & "project: sb" & LF
     & "tags: [synapse, vault-infra]" & LF
     & "sources:" & LF
     & "  - path: src/main.zig" & LF
     & "    hash: " & Hash & LF
     & "status: TODO" & LF
     & "---" & LF
     & LF
     & "# State machine" & LF
     & LF
     & "tags: fake decoy in the body" & LF;

   function Replace_All (S, Pattern, By : String) return String is
      Result : Unbounded_String;
      I      : Natural := S'First;
   begin
      while I <= S'Last loop
         if I + Pattern'Length - 1 <= S'Last
           and then S (I .. I + Pattern'Length - 1) = Pattern
         then
            Append (Result, By);
            I := I + Pattern'Length;
         else
            Append (Result, S (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Result);
   end Replace_All;

   --  The same text with every line ending CR LF.
   function As_CRLF (S : String) return String
   is (Replace_All (S, String'[LF], String'[CR, LF]));

   function Contains (S, Part : String) return Boolean
   is (Ada.Strings.Fixed.Index (S, Part) > 0);

   function Text_Of (Note : String; Item : Span) return String
   is (Note (Note'First + Item.First .. Note'First + Item.Stop - 1));

   function Field (Note, Key : String) return String is
      Found : constant Maybe_Span := Find_Field (Note, Key);
   begin
      Assert (Found.Found, "field present: " & Key);
      return Text_Of (Note, Found.Item);
   end Field;

   function Has_Field (Note, Key : String) return Boolean
   is (Find_Field (Note, Key).Found);

   function Scalar_Of (Note, Key : String) return String is
      Found : constant Maybe_Text := Scalar (Note, Key);
   begin
      Assert (Found.Found, "scalar present: " & Key);
      return To_String (Found.Item);
   end Scalar_Of;

   ---------------------------------------------------------------------------
   --  Writing one field
   ---------------------------------------------------------------------------

   procedure A_Scalar_Set_Replaces_Only_Its_Line

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);
      Got      : constant String :=
        Set_Scalar (Sample, "status", "IN-PROGRESS");
      Expected : constant String :=
        Replace_All (Sample, "status: TODO", "status: IN-PROGRESS");
   begin
      Assert (Got = Expected, "exactly one line changed");
      Assert (Contains (Got, "tags: fake decoy in the body" & LF),
              "the body is untouched");
   end A_Scalar_Set_Replaces_Only_Its_Line;

   procedure A_New_Key_Goes_Before_The_Closing_Fence
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant String := Set_Scalar (Sample, "priority", "high");
   begin
      Assert (Contains (Got, "status: TODO" & LF & "priority: high" & LF
                             & "---" & LF),
              "after the last key, before the fence");
      Assert
        (Got'Length = Sample'Length + String'("priority: high" & LF)'Length,
              "and nothing else added");
   end A_New_Key_Goes_Before_The_Closing_Fence;

   procedure Lists_Are_Written_As_Flow_Sequences

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);
      Items : constant String_Array :=
        [To_Unbounded_String ("a"), To_Unbounded_String ("b")];
   begin
      Assert (Contains (Set_List (Sample, "status", Items),
                        "status: [a, b]" & LF),
              "a list on an existing scalar key changes its type");
      Assert (Contains (Set_List (Sample, "reviewers",
                                  [To_Unbounded_String ("alice"),
                                   To_Unbounded_String ("bob")]),
                        "reviewers: [alice, bob]" & LF),
              "a list on an absent key");
      Assert (Contains (Set_List (Sample, "tags", []), "tags: []" & LF),
              "an empty list");
   end Lists_Are_Written_As_Flow_Sequences;

   procedure A_Tags_List_Is_Never_A_Quoted_String

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);
      Got : constant String :=
        Set_List (Sample, "tags",
                  [To_Unbounded_String ("synapse"),
                   To_Unbounded_String ("vault-infra"),
                   To_Unbounded_String ("architecture")]);
   begin
      Assert
        (Contains (Got, "tags: [synapse, vault-infra, architecture]" & LF),
              "a real flow sequence");
      Assert (not Contains (Got, "tags: '["), "not a single-quoted string");
      Assert (not Contains (Got, "tags: ""["), "not a double-quoted string");
   end A_Tags_List_Is_Never_A_Quoted_String;

   procedure Values_Are_Quoted_Only_When_Needed

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);
   begin
      Assert (Contains (Set_Scalar (Sample, "title", "a: title with a colon"),
                        "title: ""a: title with a colon""" & LF),
              "a colon and a space");
      Assert (Contains (Set_Scalar (Sample, "title", "123"),
                        "title: ""123""" & LF),
              "all digits stay a string");
      Assert (Contains (Set_Scalar (Sample, "title", "plain"),
                        "title: plain" & LF),
              "plain text is not quoted");
      Assert (Contains (Set_Scalar (Sample, "title", """hi"" there"),
                        "title: """ & Backslash & """hi" & Backslash
                        & """ there""" & LF),
              "inner quotes are escaped");
      Assert (Contains (Set_Scalar (Sample, "title", "say ""hi"""),
                        "title: say ""hi""" & LF),
              "a quote inside plain text needs no quoting");
      Assert (Contains (Set_Scalar (Sample, "title", "line1" & LF & "line2"),
                        "title: ""line1" & Backslash & "nline2""" & LF),
              "a newline is escaped");
   end Values_Are_Quoted_Only_When_Needed;

   procedure Needs_Quoting_Follows_The_Writers_Rules
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Quoted_Case (S : String) is
      begin
         Assert (Needs_Quoting (S), "needs quotes: '" & S & "'");
      end Quoted_Case;

      procedure Plain_Case (S : String) is
      begin
         Assert (not Needs_Quoting (S), "plain: '" & S & "'");
      end Plain_Case;
   begin
      Quoted_Case ("");
      Quoted_Case (" x");
      Quoted_Case ("x ");
      Quoted_Case (HT & "x");
      Quoted_Case ("x" & HT);
      Quoted_Case ("a: b");
      Quoted_Case ("a:");
      Quoted_Case ("a #b");
      Quoted_Case ("a" & LF & "b");
      Quoted_Case ("a" & CR & "b");
      Quoted_Case ([CR]);
      for First of String'("""'#&*!|>%@`[]{},") loop
         Quoted_Case (First & "x");
      end loop;
      Quoted_Case ("true");
      Quoted_Case ("false");
      Quoted_Case ("null");
      Quoted_Case ("~");
      Quoted_Case ("0");
      Quoted_Case ("0123");

      Plain_Case ("plain");
      Plain_Case ("a-b_c");
      Plain_Case ("a b");
      Plain_Case ("a:b");
      Plain_Case ("a#b");
      Plain_Case ("True");
      Plain_Case ("12a");
      Plain_Case ("a1");
      Plain_Case ("x.y");
   end Needs_Quoting_Follows_The_Writers_Rules;

   procedure A_Note_Without_Frontmatter_Is_An_Error

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);

      procedure Expect_Error (Note : String; What : String) is
         Ignored : String (1 .. 1);
         pragma Unreferenced (Ignored);
      begin
         declare
            Result : constant String := Set_Scalar (Note, "status", "x");
         begin
            Assert (False, What & " should raise, got " & Result);
         end;
      exception
         when No_Frontmatter =>
            null;
      end Expect_Error;
   begin
      Expect_Error ("# Just prose" & LF, "no fence at all");
      Expect_Error ("---" & LF & "a: b" & LF, "no closing fence");
      Expect_Error ("", "an empty note");
      Expect_Error
        (" ---" & LF & "a: b" & LF & "---" & LF, "an indented fence");
   end A_Note_Without_Frontmatter_Is_An_Error;

   ---------------------------------------------------------------------------
   --  Tags
   ---------------------------------------------------------------------------

   Bare : constant String :=
     "---" & LF & "title: ""x""" & LF & "---" & LF & "body" & LF;

   One_Tag : constant String :=
     "---" & LF & "title: ""x""" & LF & "tags: [synapse]" & LF & "---" & LF
     & "body" & LF;

   procedure Tags_Are_Added (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Contains (Add_Tag (Bare, "synapse"), "tags: [synapse]" & LF),
              "creates the field");
      Assert (Contains (Add_Tag (Sample, "zig"),
                        "tags: [synapse, vault-infra, zig]" & LF),
              "appends to an existing list");
      Assert (Add_Tag (Sample, "synapse") = Sample,
              "an existing tag leaves the note byte for byte alone");
   end Tags_Are_Added;

   procedure Tags_Are_Removed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Contains (Remove_Tag (One_Tag, "synapse"), "tags: []" & LF),
              "the last tag leaves an empty list, not a deleted field");
      Assert (Contains (Remove_Tag (Sample, "synapse"),
                        "tags: [vault-infra]" & LF),
              "one of two");
      Assert (Remove_Tag (Sample, "nonexistent") = Sample, "an absent tag");
      Assert (Remove_Tag (Bare, "synapse") = Bare, "a note without tags");
   end Tags_Are_Removed;

   procedure Tags_Are_Parsed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Parsed (Note : String) return String is
         Items  : constant String_Array := Parse_Tags (Note);
         Result : Unbounded_String;
      begin
         for I in Items'Range loop
            Append (Result, (if I = Items'First then "" else "|")
                            & To_String (Items (I)));
         end loop;
         return To_String (Result);
      end Parsed;

      function With_Tags (Raw : String) return String
      is ("---" & LF & "tags: " & Raw & LF & "---" & LF);
   begin
      Assert (Parsed (Sample) = "synapse|vault-infra", "a flow list");
      Assert (Parsed (With_Tags ("[a,b ,  c]")) = "a|b|c", "blanks trimmed");
      Assert
        (Parsed (With_Tags ("[""a"", ""b c""]")) = "a|b c",
         "quotes removed");
      Assert (Parsed (With_Tags ("[]")) = "", "an empty list");
      Assert (Parsed (With_Tags ("[ ]")) = "", "a blank list");
      Assert (Parsed (With_Tags ("a, b")) = "", "not a flow sequence");
      Assert (Parsed (Bare) = "", "no tags field");
      Assert (Parsed ("no frontmatter") = "", "no frontmatter");
      Assert (Parsed (With_Tags ("[a,,b]")) = "a||b", "an empty item stays");
   end Tags_Are_Parsed;

   ---------------------------------------------------------------------------
   --  Reading
   ---------------------------------------------------------------------------

   procedure Fields_Are_Read_From_The_Frontmatter

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);
   begin
      Assert (Field (Sample, "title") = "State machine", "quotes stripped");
      Assert (Field (Sample, "project") = "sb", "an unquoted value");
      Assert
        (Field (Sample, "tags") = "[synapse, vault-infra]",
         "a list as text");
      Assert (not Has_Field (Sample, "missing"), "an absent field");
      Assert (not Has_Field (Sample, "path"), "nested keys are not top level");
      Assert (Field (Sample, "status") = "TODO", "the last key");
   end Fields_Are_Read_From_The_Frontmatter;

   procedure A_Lookup_Matches_A_Whole_Key (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Note : constant String :=
        "---" & LF & "subtitle: nope" & LF & "titled: nope" & LF
        & "title: yes" & LF & "---" & LF;
   begin
      Assert (Field (Note, "title") = "yes", "not a suffix or prefix");
      Assert (not Has_Field (Note, "tit"), "not a prefix of a key");
      Assert (Is_Key_Line ("title: x", "title"), "a key line");
      Assert (not Is_Key_Line ("subtitle: x", "title"), "a suffix");
      Assert (not Is_Key_Line ("titled: x", "title"), "a longer key");
      Assert (not Is_Key_Line ("title", "title"), "no colon");
      Assert (not Is_Key_Line (" title: x", "title"), "indented");
      Assert (Is_Key_Line ("title:", "title"), "an empty value");
   end A_Lookup_Matches_A_Whole_Key;

   procedure A_Field_Is_Never_Read_From_The_Body

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);
      Note : constant String :=
        "---" & LF & "title: real" & LF & "---" & LF
        & "status: in the body" & LF;
   begin
      Assert (not Has_Field (Note, "status"), "a key in the body");
      Assert (not Has_Field ("status: only prose" & LF, "status"),
              "a note with no frontmatter");
   end A_Field_Is_Never_Read_From_The_Body;

   procedure One_Quote_Is_Stripped_At_Each_End

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);

      function Value_Of (Raw : String) return String
      is (Field ("---" & LF & "k: " & Raw & LF & "---" & LF, "k"));
   begin
      Assert (Value_Of ("""x""") = "x", "a pair");
      Assert
        (Value_Of ("""""x""""") = """x""",
         "no more than one at each end");
      Assert (Value_Of ("""ends with " & Backslash & """""")
              = "ends with " & Backslash & """",
              "an escaped closing quote keeps its character");
      Assert (Value_Of ("x") = "x", "no quotes");
      Assert (Value_Of ("""") = "", "one lone quote");
      Assert (Value_Of ("   x") = "x", "leading blanks");
      Assert (Value_Of (HT & "x") = "x", "a leading tab");
      Assert (Value_Of ("") = "", "an empty value");
   end One_Quote_Is_Stripped_At_Each_End;

   procedure Scalars_Resolve_Their_Escapes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Scalar_Of_Raw (Raw : String) return String
      is (Scalar_Of ("---" & LF & "k: " & Raw & LF & "---" & LF, "k"));
   begin
      Assert (Scalar_Of_Raw ("""a " & Backslash & """b" & Backslash & """""")
              = "a ""b""", "escaped quotes");
      Assert (Scalar_Of_Raw ("""C:" & Backslash & Backslash & "path""")
              = "C:" & Backslash & "path", "an escaped backslash");
      Assert (Scalar_Of_Raw ("""a" & Backslash & "nb" & Backslash & "rc""")
              = "a" & LF & "b" & CR & "c", "newline and carriage return");
      Assert (Scalar_Of_Raw ("""a" & Backslash & "tb""")
              = "a" & Backslash & "tb", "an unknown escape is kept");
      Assert
        (Scalar_Of_Raw ("fw-core") = "fw-core",
         "an unquoted scalar as written");
      Assert (Scalar_Of_Raw ("""") = """", "a lone quote is not a pair");
      declare
         Missing : constant Maybe_Text := Scalar (Sample, "missing");
      begin
         Assert (not Missing.Found, "an absent key");
      end;
   end Scalars_Resolve_Their_Escapes;

   procedure Key_Values_Split_On_The_First_Colon

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);

      procedure Check (Line : String; Want_Found : Boolean;
                       Want_Key, Want_Value : String)
      is
         Found      : Boolean;
         Key, Value : Span;
      begin
         Split_Key_Value (Line, Found, Key, Value);
         Assert (Found = Want_Found, "found for '" & Line & "'");
         if Found then
            Assert (Text_Of (Line, Key) = Want_Key, "key of '" & Line & "'");
            Assert
              (Text_Of (Line, Value) = Want_Value,
               "value of '" & Line & "'");
         end if;
      end Check;
   begin
      Check ("title: Hello", True, "title", "Hello");
      Check ("  title : Hello  ", False, "", "");
      Check ("title : Hello  ", True, "title", "Hello");
      Check ("a: b: c", True, "a", "b: c");
      Check ("key:", True, "key", "");
      Check ("no colon", False, "", "");
      Check (": value", False, "", "");
      Check ("  nested: x", False, "", "");
      Check (HT & "nested: x", False, "", "");
      Check ("", False, "", "");
   end Key_Values_Split_On_The_First_Colon;

   procedure The_Block_Is_Located (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      B : constant Block := Locate (Sample);
   begin
      Assert (B.Present, "present");
      Assert (B.Lines_Start = 4, "the first line follows the opening fence");
      Assert (Sample (Sample'First + B.Close .. Sample'First + B.Close + 2)
              = "---", "Close is the closing fence's line");
      Assert (B.Body_Start = B.Close + 4, "the body follows its line ending");
      Assert (Text_Of (Sample, Body_After (Sample))
              = LF & "# State machine" & LF & LF
                & "tags: fake decoy in the body" & LF, "the body");
      Assert (Text_Of ("just prose", Body_After ("just prose")) = "just prose",
              "no block: the whole text");
      Assert (not Locate ("---" & LF & "no end" & LF).Present,
              "an unclosed block is not frontmatter");
      Assert (Locate ("---" & LF & "---" & LF).Present, "an empty block");
      Assert (Locate ("---" & LF & "a: b" & LF & "---").Present,
              "the closing fence may end the text");
      Assert (not Locate ("--- " & LF & "---" & LF).Present,
              "the opening fence is exactly three dashes");
      Assert (not Locate ("----" & LF & "---" & LF).Present, "four dashes");
   end The_Block_Is_Located;

   procedure Lines_Are_Walked_Without_Their_Endings

     (T : in out Test_Cases_Class)

   is
      pragma Unreferenced (T);

      function Walk (Note : String) return String is
         B        : constant Block := Locate (Note);
         Position : Natural := B.Lines_Start;
         Line     : Span;
         Found    : Boolean;
         Result   : Unbounded_String;
      begin
         loop
            Next_Line (Note, B, Position, Line, Found);
            exit when not Found;
            Append (Result, "[" & Text_Of (Note, Line) & "]");
         end loop;
         return To_String (Result);
      end Walk;

      Note : constant String :=
        "---" & LF & "a: 1" & LF & LF & "b: 2" & LF & "---" & LF;
   begin
      Assert (Walk (Note) = "[a: 1][][b: 2]", "lines, an empty one included");
      Assert (Walk (As_CRLF (Note)) = "[a: 1][][b: 2]", "without the CR");
      Assert (Walk ("---" & LF & "---" & LF) = "", "an empty block");
   end Lines_Are_Walked_Without_Their_Endings;

   ---------------------------------------------------------------------------
   --  CRLF
   ---------------------------------------------------------------------------

   procedure CRLF_Notes_Have_Frontmatter (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Note : constant String := As_CRLF (Sample);
   begin
      Assert (Locate (Note).Present, "an opening fence with CR LF");
      Assert (Field (Note, "status") = "TODO", "the value has no CR");
      Assert (Field (Note, "title") = "State machine", "a quoted value");
      Assert (Scalar_Of (Note, "title") = "State machine", "Scalar too");
      Assert (Text_Of (Note, Body_After (Note))
              = CR & LF & "# State machine" & CR & LF & CR & LF
                & "tags: fake decoy in the body" & CR & LF,
              "the body after the closing fence's line");
   end CRLF_Notes_Have_Frontmatter;

   procedure CRLF_Writes_Keep_Line_Endings (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Note : constant String := As_CRLF (Sample);
   begin
      Assert (Set_Scalar (Note, "status", "DONE")
              = Replace_All (Note, "status: TODO", "status: DONE"),
              "a replaced line keeps its CR LF");
      Assert (Contains (Set_Scalar (Note, "priority", "high"),
                        "status: TODO" & CR & LF & "priority: high" & CR & LF
                        & "---" & CR & LF),
              "an inserted line ends with CR LF");
      Assert (Contains (Add_Tag (Note, "zig"),
                        "tags: [synapse, vault-infra, zig]" & CR & LF),
              "tags on a CRLF note");
      declare
         Bare_CRLF : constant String := As_CRLF (Bare);
         Got       : constant String := Set_Scalar (Bare_CRLF, "a", "b");
      begin
         Assert (Got = "---" & CR & LF & "title: ""x""" & CR & LF & "a: b"
                       & CR & LF & "---" & CR & LF & "body" & CR & LF,
                 "an insert into a CRLF block");
      end;
   end CRLF_Writes_Keep_Line_Endings;

   procedure A_Closing_Fence_May_End_The_Text (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Note : constant String := "---" & LF & "a: b" & LF & "---";
   begin
      Assert (Field (Note, "a") = "b", "readable");
      Assert (Set_Scalar (Note, "c", "d")
              = "---" & LF & "a: b" & LF & "c: d" & LF & "---",
              "writable");
      Assert (Set_Scalar ("---" & LF & "---", "a", "b")
              = "---" & LF & "a: b" & LF & "---", "an empty block");
   end A_Closing_Fence_May_End_The_Text;

   procedure UTF8_Values_Pass_Through (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Title : constant String :=
        UTF8.Encode (16#43F#) & UTF8.Encode (16#440#) & UTF8.Encode (16#438#)
        & " " & UTF8.Encode (16#1F600#);
      Got   : constant String := Set_Scalar (Sample, "title", Title);
   begin
      Assert
        (Contains (Got, "title: " & Title & LF),
         "not quoted, not altered");
      Assert (Scalar_Of (Got, "title") = Title, "reads back");
   end UTF8_Values_Pass_Through;

   ---------------------------------------------------------------------------
   --  Properties
   ---------------------------------------------------------------------------

   Seed : Interfaces.Unsigned_64 := 20_261_011;

   function Next (Limit : Positive) return Natural is
      use type Interfaces.Unsigned_64;
   begin
      Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural ((Seed / 2**20) mod Interfaces.Unsigned_64 (Limit));
   end Next;

   function Random_Value return String is
      Result : Unbounded_String;
   begin
      for I in 1 .. Next (10) loop
         case Next (14) is
            when 0 =>
               Append (Result, ' ');

            when 1 =>
               Append (Result, '"');

            when 2 =>
               Append (Result, Backslash);

            when 3 =>
               Append (Result, LF);

            when 4 =>
               Append (Result, CR);

            when 5 =>
               Append (Result, ':');

            when 6 =>
               Append (Result, '#');

            when 7 =>
               Append (Result, HT);

            when 8 =>
               Append (Result, UTF8.Encode (16#80# + Next (16#7F80#)));

            when 9 =>
               Append (Result, Character'Val (48 + Next (10)));

            when others =>
               Append (Result, Character'Val (97 + Next (26)));
         end case;
      end loop;
      return To_String (Result);
   end Random_Value;

   function Hex (S : String) return String is
      Digits_Of : constant String := "0123456789abcdef";
      Result    : Unbounded_String;
   begin
      for C of S loop
         Append (Result, Digits_Of (Character'Pos (C) / 16 + 1)
                         & Digits_Of (Character'Pos (C) mod 16 + 1) & ' ');
      end loop;
      return "[" & To_String (Result) & "]";
   end Hex;

   procedure A_Written_Scalar_Reads_Back (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      for I in 1 .. 5_000 loop
         declare
            Value : constant String := Random_Value;
            Note  : constant String :=
              (if I mod 3 = 0 then As_CRLF (Sample) else Sample);
            Key   : constant String :=
              (if I mod 2 = 0 then "title" else "extra");
            Got   : constant String := Set_Scalar (Note, Key, Value);
         begin
            if Scalar_Of (Got, Key) /= Value then
               Assert (False, "case" & I'Image & ": " & Hex (Value)
                       & " read back as " & Hex (Scalar_Of (Got, Key)));
            end if;
            if Set_Scalar (Got, Key, Value) /= Got then
               Assert
                 (False,
                  "case" & I'Image & ": setting it again changed the note");
            end if;
         end;
      end loop;
   end A_Written_Scalar_Reads_Back;

   --  The text with line number N removed (lines end in LF).
   function Without_Line (Text : String; N : Positive) return String is
      Result : Unbounded_String;
      Line   : Natural := 1;
   begin
      for C of Text loop
         if Line /= N then
            Append (Result, C);
         end if;
         if C = LF then
            Line := Line + 1;
         end if;
      end loop;
      return To_String (Result);
   end Without_Line;

   function Random_Note return String is
      Result : Unbounded_String := To_Unbounded_String ("---" & LF);
   begin
      for I in 1 .. Next (6) loop
         case Next (4) is
            when 0 =>
               Append (Result, "k" & Natural'Image (Next (4)) (2 .. 2)
                               & ": v" & Natural'Image (I) (2 .. 2) & LF);

            when 1 =>
               Append (Result, "  nested" & Natural'Image (Next (4)) (2 .. 2)
                               & ": x" & LF);

            when 2 =>
               Append (Result, "k" & Natural'Image (Next (4)) (2 .. 2)
                               & ": ""q" & Natural'Image (I) (2 .. 2) & """"
                               & LF);

            when others =>
               Append (Result, "k" & Natural'Image (Next (4)) (2 .. 2)
                               & ": [a, b]" & LF);
         end case;
      end loop;
      Append (Result, "---" & LF & "body k0: z" & LF);
      return To_String (Result);
   end Random_Note;

   procedure A_Write_Changes_One_Line_Only (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Replaced : Natural := 0;
      Inserted : Natural := 0;
   begin
      for I in 1 .. 4_000 loop
         declare
            Note   : constant String := Random_Note;
            Key    : constant String :=
              "k" & Natural'Image (Next (5)) (2 .. 2);
            Got    : constant String := Set_Scalar (Note, Key, "new");
            Line   : constant Maybe_Span := Find_Key_Line (Note, Key);
            Before : constant Natural :=
              (if Line.Found
               then Ada.Strings.Fixed.Count
                      (Note (Note'First .. Note'First + Line.Item.First - 1),
                       String'[LF]) + 1
               else 0);
         begin
            if Line.Found then
               Replaced := Replaced + 1;
               if Without_Line (Got, Before) /= Without_Line (Note, Before)
               then
                  Assert (False, "case" & I'Image & ": more than line"
                          & Before'Image & " changed");
               end if;
               if not Contains (Got, Key & ": new" & LF) then
                  Assert
                    (False,
                     "case" & I'Image & ": the new line is missing");
               end if;
            else
               Inserted := Inserted + 1;
               if Got'Length /= Note'Length + Key'Length + 6 then
                  Assert
                    (False,
                     "case" & I'Image & ": the insert is the wrong size");
               end if;
               if Replace_All (Got, Key & ": new" & LF, "") /= Note then
                  Assert
                    (False,
                     "case" & I'Image & ": the insert changed other text");
               end if;
            end if;
         end;
      end loop;
      Assert (Replaced > 500 and then Inserted > 500,
              "both paths were exercised");
   end A_Write_Changes_One_Line_Only;

   procedure Written_Tags_Parse_Back (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      for I in 1 .. 2_000 loop
         declare
            Items : String_Array (1 .. Next (5));
         begin
            for Item of Items loop
               Item := To_Unbounded_String
                 (Ada.Strings.Fixed.Trim
                    (Natural'Image (Next (100000)), Ada.Strings.Both)
                  & (if Next (2) = 0 then "-t" else ""));
            end loop;
            declare
               Got    : constant String := Set_List (Sample, "tags", Items);
               Parsed : constant String_Array := Parse_Tags (Got);
            begin
               if Parsed'Length /= Items'Length then
                  Assert (False, "case" & I'Image & ": the count changed");
               end if;
               for K in Items'Range loop
                  if Parsed (Parsed'First + K - 1) /= Items (K) then
                     Assert (False, "case" & I'Image & ": an item changed");
                  end if;
               end loop;
            end;
         end;
      end loop;
   end Written_Tags_Parse_Back;

   procedure Random_Text_Never_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Alphabet : constant String :=
        "-:[]""," & Backslash & " " & LF & CR & HT & "ab#";
   begin
      for I in 1 .. 20_000 loop
         declare
            Text : String (1 .. Next (40));
         begin
            for C of Text loop
               C := Alphabet (Alphabet'First + Next (Alphabet'Length));
            end loop;
            if I mod 2 = 0 and then Text'Length >= 4 then
               Text (1 .. 4) := "---" & LF;
            end if;
            declare
               B       : constant Block := Locate (Text);
               Ignored : constant Maybe_Span := Find_Field (Text, "a");
               Tags    : constant String_Array := Parse_Tags (Text);
               Value   : constant Maybe_Text := Scalar (Text, "b");
               After_Body : constant Span := Body_After (Text);
            begin
               if B.Present then
                  declare
                     Written : constant String := Set_Scalar (Text, "a", "v");
                     With_Tag : constant String := Add_Tag (Text, "t");
                     Removed : constant String := Remove_Tag (Text, "t");
                  begin
                     if not Has_Frontmatter (Written)
                       or else not Has_Frontmatter (With_Tag)
                       or else not Has_Frontmatter (Removed)
                     then
                        Assert (False, "a write lost the frontmatter");
                     end if;
                  end;
               end if;
               if Tags'Length > 1_000 or else After_Body.Stop /= Text'Length
                 or else (Value.Found and then False)
               then
                  Assert (False, "unexpected result");
               end if;
            end;
         exception
            when E : others =>
               Assert (False, "raised " & Ada.Exceptions.Exception_Name (E));
         end;
      end loop;
   end Random_Text_Never_Raises;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Frontmatter");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Scalar_Set_Replaces_Only_Its_Line'Access,
         "A scalar set replaces only its line");
      Register_Routine
        (T, A_New_Key_Goes_Before_The_Closing_Fence'Access,
         "A new key goes before the closing fence");
      Register_Routine
        (T, Lists_Are_Written_As_Flow_Sequences'Access,
         "Lists are written as flow sequences");
      Register_Routine
        (T, A_Tags_List_Is_Never_A_Quoted_String'Access,
         "A tags list is never a quoted string");
      Register_Routine
        (T, Values_Are_Quoted_Only_When_Needed'Access,
         "Values are quoted only when needed");
      Register_Routine
        (T, Needs_Quoting_Follows_The_Writers_Rules'Access,
         "Needs_Quoting follows the writer's rules");
      Register_Routine
        (T, A_Note_Without_Frontmatter_Is_An_Error'Access,
         "A note without frontmatter is an error");
      Register_Routine (T, Tags_Are_Added'Access, "Tags are added");
      Register_Routine (T, Tags_Are_Removed'Access, "Tags are removed");
      Register_Routine (T, Tags_Are_Parsed'Access, "Tags are parsed");
      Register_Routine
        (T, Fields_Are_Read_From_The_Frontmatter'Access,
         "Fields are read from the frontmatter");
      Register_Routine
        (T, A_Lookup_Matches_A_Whole_Key'Access,
         "A lookup matches a whole key");
      Register_Routine
        (T, A_Field_Is_Never_Read_From_The_Body'Access,
         "A field is never read from the body");
      Register_Routine
        (T, One_Quote_Is_Stripped_At_Each_End'Access,
         "One quote is stripped at each end");
      Register_Routine
        (T, Scalars_Resolve_Their_Escapes'Access,
         "Scalars resolve their escapes");
      Register_Routine
        (T, Key_Values_Split_On_The_First_Colon'Access,
         "Key values split on the first colon");
      Register_Routine
        (T, The_Block_Is_Located'Access, "The block is located");
      Register_Routine
        (T, Lines_Are_Walked_Without_Their_Endings'Access,
         "Lines are walked without their endings");
      Register_Routine
        (T, CRLF_Notes_Have_Frontmatter'Access, "CRLF notes have frontmatter");
      Register_Routine
        (T, CRLF_Writes_Keep_Line_Endings'Access,
         "CRLF writes keep line endings");
      Register_Routine
        (T, A_Closing_Fence_May_End_The_Text'Access,
         "A closing fence may end the text");
      Register_Routine
        (T, UTF8_Values_Pass_Through'Access, "UTF-8 values pass through");
      Register_Routine
        (T, A_Written_Scalar_Reads_Back'Access, "A written scalar reads back");
      Register_Routine
        (T, A_Write_Changes_One_Line_Only'Access,
         "A write changes one line only");
      Register_Routine
        (T, Written_Tags_Parse_Back'Access, "Written tags parse back");
      Register_Routine
        (T, Random_Text_Never_Raises'Access, "Random text never raises");
   end Register_Tests;

end Synapse.Core.Frontmatter.Tests;
