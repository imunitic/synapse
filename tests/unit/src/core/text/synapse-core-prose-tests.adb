with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Interfaces;

package body Synapse.Core.Prose.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);

   ---------------------------------------------------------------------------

   procedure Excluded_Lines_Never_Count (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      procedure Excluded (Line : String) is
      begin
         Assert (Is_Excluded_Line (Line), "excluded: '" & Line & "'");
      end Excluded;

      procedure Prose_Line (Line : String) is
      begin
         Assert (not Is_Excluded_Line (Line), "prose: '" & Line & "'");
      end Prose_Line;
   begin
      Excluded ("");
      Excluded ("" & CR);
      Excluded ("  indented");
      Excluded (Character'Val (9) & "tab indented");
      Excluded ("# Heading");
      Excluded ("#no space still a hash");
      Excluded ("> quote");
      Excluded ("| a | b |");
      Excluded ("- item");
      Excluded ("* item");
      Excluded ("+ item");
      Excluded ("1. item");
      Excluded ("12) item");
      Excluded ("1. ");
      Excluded ("```");
      Excluded ("~~~ text");
      Prose_Line ("plain words");
      Prose_Line ("-no space");
      Prose_Line ("*emphasis* start");
      Prose_Line ("1.5 is a number");
      Prose_Line ("1.");
      Prose_Line ("12");
      Prose_Line ("a - b");
      Prose_Line ("x | y");
      Prose_Line ("é text");
   end Excluded_Lines_Never_Count;

   procedure A_Paragraph_Of_Two_Lines_Is_Hard_Wrapped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (not No_Hard_Wrap ("This is a sentence that got" & LF
                                & "hard-wrapped across two lines." & LF),
              "two lines");
      Assert (No_Hard_Wrap ("One continuous line." & LF), "one line");
      Assert (No_Hard_Wrap ("One." & LF & LF & "Two." & LF),
              "two paragraphs");
      Assert (No_Hard_Wrap (""), "empty");
      Assert (No_Hard_Wrap ("one"), "no line break");
      Assert (not No_Hard_Wrap ("a" & LF & "b"), "no final line break");
      Assert (not No_Hard_Wrap ("a" & CR & LF & "b" & CR & LF), "CRLF");
      Assert (not No_Hard_Wrap ("a" & LF & "b" & LF & "c" & LF), "three");
      Assert (No_Hard_Wrap ("a" & LF & "# h" & LF & "b" & LF),
              "a heading ends the run");
      Assert (No_Hard_Wrap ("a" & LF & "> q" & LF & "b" & LF),
              "a quote ends it");
      Assert (not No_Hard_Wrap ("# h" & LF & "a" & LF & "b" & LF),
              "after a heading");
   end A_Paragraph_Of_Two_Lines_Is_Hard_Wrapped;

   procedure Tables_Lists_And_Code_Are_Not_Paragraphs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (No_Hard_Wrap
                ("| a | b |" & LF & "| c | d |" & LF & LF
                 & "- item one" & LF & "  a continuation paragraph" & LF
                 & "  and another line" & LF & LF
                 & "```" & LF & "code line one" & LF & "code line two" & LF
                 & "```" & LF),
              "table, list continuation and fence");
      Assert (No_Hard_Wrap ("```" & LF & "two" & LF & "lines" & LF & "```"
                            & LF), "backtick fence");
      Assert (No_Hard_Wrap ("~~~" & LF & "two" & LF & "lines" & LF & "~~~"
                            & LF), "tilde fence");
      Assert (No_Hard_Wrap ("```" & LF & "two" & LF & "lines" & LF),
              "an unclosed fence hides the rest");
      Assert (not No_Hard_Wrap ("```" & LF & "x" & LF & "```" & LF & "two"
                                & LF & "lines" & LF),
              "prose after a fence counts");
      Assert (No_Hard_Wrap ("1. one" & LF & "2) two" & LF & "+ three" & LF),
              "list markers");
      Assert (not No_Hard_Wrap ("1.5 apples" & LF & "2.5 pears" & LF),
              "decimals are prose");
   end Tables_Lists_And_Code_Are_Not_Paragraphs;

   function Wrapped (Text : String; Width : Positive) return Boolean
   is (Hard_Wrap (Text, Width));

   procedure Greedy_Wrapping_Follows_The_Nearest_Fit
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      --  Width 20: "This is a test of hard" is 22, which overshoots by 2 and
      --  lands nearer than stopping at "of" (17, short by 3).
      Assert (Wrapped ("This is a test of hard" & LF & "wrap logic here."
                       & LF, 20), "the nearer overshoot stays");
      Assert (not Wrapped ("This is a test of" & LF & "hard wrap logic here."
                           & LF, 20), "stopped too early");
      Assert (not Wrapped ("This is a test of hard wrap" & LF & "logic here."
                           & LF, 20), "packed past the boundary word");
      Assert (Wrapped ("```" & LF & "not wrapped" & LF & "at all" & LF
                       & "```" & LF, 20), "fenced code is skipped");
      Assert (Wrapped ("one" & LF, 20), "a single short line");
      Assert (Wrapped ("", 20), "empty");
      Assert (Wrapped ("aaa bbb" & LF, 7), "exactly the width");
      Assert (Wrapped ("aaa" & LF & "bbb" & LF, 5),
              "a tie starts the next line");
      Assert (not Wrapped ("aaa bbb" & LF, 5), "a tie must not be joined");
      Assert (Wrapped ("aaaa bbbb" & LF, 5) = False, "9 > 5 must break");
      Assert (Wrapped ("aaaa" & LF & "bbbb" & LF, 5), "so it breaks");
      Assert (Wrapped ("aaaaaaaaaaaa" & LF & "bb" & LF, 5),
              "a long word stays alone");
      Assert (Wrapped ("aaaaaaaaaaaa bb" & LF, 5) = False,
              "a short word is not joined to it");
      Assert (Wrapped ("aa bb" & LF & "cc" & LF, 5), "fills toward the width");
      Assert (not Wrapped ("aa" & LF & "bb cc" & LF, 5), "reflowed");
      Assert (Wrapped ("aa  bb" & CR & LF & "cc" & CR & LF, 5),
              "extra blanks and CRLF do not matter");
      Assert (Wrapped ("   " & LF, 5), "blank only");
   end Greedy_Wrapping_Follows_The_Nearest_Fit;

   procedure Extra_Or_Missing_Words_Fail (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Wrapped ("aa bb cc" & LF & "dd" & LF, 5),
              "an extra word on the first line");
      Assert (Wrapped ("aa bb" & LF & "xx" & LF, 5), "another word is fine");
      Assert (not Wrapped ("aa" & LF & "bb" & LF & "cc" & LF, 5),
              "words that fit but are split");
   end Extra_Or_Missing_Words_Fail;

   procedure Stray_Frontmatter_Needs_A_Value_Between_Fences
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (not No_Stray_Frontmatter
                    ("Some prose." & LF & LF & "---" & LF
                     & "leftover: fragment" & LF & "---" & LF & LF
                     & "More prose." & LF),
              "a pasted block");
      Assert (No_Stray_Frontmatter
                ("Above." & LF & LF & "---" & LF & LF & "Below." & LF),
              "a lone divider");
      Assert (No_Stray_Frontmatter
                ("Example:" & LF & LF & "```" & LF & "---" & LF & "key: value"
                 & LF & "---" & LF & "```" & LF),
              "inside a fence");
      Assert (No_Stray_Frontmatter ("Just prose." & LF), "clean");
      Assert (No_Stray_Frontmatter (""), "empty");
      Assert (No_Stray_Frontmatter ("---" & LF & "key:" & LF & "---" & LF),
              "a key with no value");
      Assert (No_Stray_Frontmatter ("---" & LF & "no colon" & LF & "---" & LF),
              "lines without a key");
      Assert (No_Stray_Frontmatter
                ("---" & LF & "  indented: v" & LF & "---" & LF),
              "an indented line");
      Assert (No_Stray_Frontmatter ("---" & LF & ": v" & LF & "---" & LF),
              "an empty key");
      Assert (not No_Stray_Frontmatter
                    ("---" & CR & LF & "k: v" & CR & LF & "---" & CR & LF),
              "CRLF");
      Assert (not No_Stray_Frontmatter ("---" & LF & "k: v" & LF & "---"),
              "no final line break");
      Assert (No_Stray_Frontmatter ("---" & LF & "k: v" & LF),
              "an unclosed block");
      Assert (No_Stray_Frontmatter ("--- " & LF & "k: v" & LF & "--- " & LF),
              "a divider with a trailing space is not a fence");
      Assert (No_Stray_Frontmatter
                ("---" & LF & "a" & LF & "---" & LF & "k: v" & LF & "---" & LF
                 & "---" & LF),
              "pairs are matched in order: a pair without a value is fine");
      Assert (No_Stray_Frontmatter
                ("---" & LF & "k: v" & LF & "~~~" & LF & "---" & LF & "~~~"
                 & LF),
              "a tilde fence hides the closing fence");
   end Stray_Frontmatter_Needs_A_Value_Between_Fences;

   ---------------------------------------------------------------------------
   --  Properties
   ---------------------------------------------------------------------------

   State : Interfaces.Unsigned_64 := 16#A076_1D64_78BD_642F#;

   function Next (Bound : Positive) return Natural is
   begin
      State := State * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural ((State / 65_536) mod Interfaces.Unsigned_64 (Bound));
   end Next;

   type Word_Array is array (Positive range <>) of Unbounded_String;

   function Random_Word return Unbounded_String is
      Result : Unbounded_String;
   begin
      for I in 1 .. 1 + Next (9) loop
         Append (Result, Character'Val (Character'Pos ('a') + Next (26)));
      end loop;
      return Result;
   end Random_Word;

   --  The words laid out the way the rule describes: lines of words, a line
   --  ending when the next word would be nearer the width on the next line.
   function Reference_Wrap
     (Words : Word_Array; Width : Positive) return Unbounded_String
   is
      Result  : Unbounded_String;
      Length  : Natural := 0;
      Started : Boolean := False;
      Closing : Boolean := False;  --  the line takes no further word
   begin
      for W of Words loop
         declare
            Size : constant Natural := Ada.Strings.Unbounded.Length (W);
         begin
            if not Started then
               Append (Result, W);
               Length := Size;
               Started := True;
               Closing := False;
            elsif Closing then
               Append (Result, LF);
               Append (Result, W);
               Length := Size;
               Closing := False;
            else
               declare
                  Candidate : constant Natural := Length + 1 + Size;
               begin
                  if Candidate > Width then
                     declare
                        Over  : constant Natural := Candidate - Width;
                        Under : constant Natural :=
                          (if Length < Width then Width - Length else 0);
                     begin
                        if Over >= Under then
                           Append (Result, LF);
                           Append (Result, W);
                           Length := Size;
                        else
                           Append (Result, " ");
                           Append (Result, W);
                           Length := Candidate;
                           Closing := True;
                        end if;
                     end;
                  else
                     Append (Result, " ");
                     Append (Result, W);
                     Length := Candidate;
                  end if;
               end;
            end if;
         end;
      end loop;
      Append (Result, LF);
      return Result;
   end Reference_Wrap;

   function Lines_In (S : String) return Natural is
      Count : Natural := 0;
   begin
      for C of S loop
         if C = LF then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Lines_In;

   procedure Reference_Wrapped_Text_Always_Passes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for Round in 1 .. 1_500 loop
         declare
            Words : Word_Array (1 .. 1 + Next (25));
            Width : constant Positive := 3 + Next (40);
         begin
            for W of Words loop
               W := Random_Word;
            end loop;
            declare
               Text : constant String :=
                 To_String (Reference_Wrap (Words, Width));
            begin
               Assert (Hard_Wrap (Text, Width),
                       "reference wrap passes, round" & Round'Image);
               Assert (No_Hard_Wrap (Text) = (Lines_In (Text) <= 1),
                       "and is hand-wrapped exactly when it has two lines");
            end;
         end;
      end loop;
   end Reference_Wrapped_Text_Always_Passes;

   procedure Moving_A_Break_Always_Fails (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Tried : Natural := 0;
   begin
      for Round in 1 .. 3_000 loop
         declare
            Words : Word_Array (1 .. 3 + Next (25));
            Width : constant Positive := 3 + Next (30);
         begin
            for W of Words loop
               W := Random_Word;
            end loop;
            declare
               Text  : constant String :=
                 To_String (Reference_Wrap (Words, Width));
               Space : Natural := 0;
               Count : Natural := 0;
            begin
               --  Turn the n-th space into a break: a word moves to the
               --  next line, or a break is removed and two lines join.
               for I in Text'Range loop
                  if Text (I) = ' ' then
                     Count := Count + 1;
                     if Count = 1 + Next (Natural'Max (1, Count)) then
                        Space := I;
                     end if;
                  end if;
               end loop;
               if Space > 0 then
                  declare
                     Broken : String := Text;
                  begin
                     Broken (Space) := LF;
                     Tried := Tried + 1;
                     Assert (not Hard_Wrap (Broken, Width),
                             "a moved break fails, round" & Round'Image);
                  end;
               end if;
            end;
         end;
      end loop;
      Assert (Tried > 500, "enough cases tried");
   end Moving_A_Break_Always_Fails;

   procedure Random_Text_Never_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Piece (N : Natural) return String
      is (case N is
            when 0 => "word ",
            when 1 => "a",
            when 2 => LF & "",
            when 3 => CR & LF,
            when 4 => "---" & LF,
            when 5 => "```" & LF,
            when 6 => "~~~" & LF,
            when 7 => "k: v" & LF,
            when 8 => "# h" & LF,
            when 9 => "- i" & LF,
            when 10 => " ",
            when 11 => "1. ",
            when 12 => Character'Val (9) & "",
            when 13 => "|",
            when others => "xx yy zz ");
   begin
      for Round in 1 .. 4_000 loop
         declare
            Text : Unbounded_String;
         begin
            for K in 1 .. Next (30) loop
               Append (Text, Piece (Next (15)));
            end loop;
            declare
               Note  : constant String := To_String (Text);
               Width : constant Positive := 1 + Next (30);
               Ignore : constant Boolean :=
                 No_Hard_Wrap (Note) or else Hard_Wrap (Note, Width)
                 or else No_Stray_Frontmatter (Note);
               pragma Unreferenced (Ignore);
            begin
               null;
            end;
         exception
            when others =>
               Assert (False, "raised on round" & Round'Image);
         end;
      end loop;
   end Random_Text_Never_Raises;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Prose");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Excluded_Lines_Never_Count'Access, "Excluded lines never count");
      Register_Routine
        (T, A_Paragraph_Of_Two_Lines_Is_Hard_Wrapped'Access,
         "A paragraph of two lines is hard-wrapped");
      Register_Routine
        (T, Tables_Lists_And_Code_Are_Not_Paragraphs'Access,
         "Tables, lists and code are not paragraphs");
      Register_Routine
        (T, Greedy_Wrapping_Follows_The_Nearest_Fit'Access,
         "Greedy wrapping follows the nearest fit");
      Register_Routine
        (T, Extra_Or_Missing_Words_Fail'Access,
         "Extra or missing words fail");
      Register_Routine
        (T, Stray_Frontmatter_Needs_A_Value_Between_Fences'Access,
         "Stray frontmatter needs a value between fences");
      Register_Routine
        (T, Reference_Wrapped_Text_Always_Passes'Access,
         "Reference-wrapped text always passes");
      Register_Routine
        (T, Moving_A_Break_Always_Fails'Access,
         "Moving a break always fails");
      Register_Routine
        (T, Random_Text_Never_Raises'Access, "Random text never raises");
   end Register_Tests;

end Synapse.Core.Prose.Tests;
