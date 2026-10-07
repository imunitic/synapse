with Ada.Characters.Latin_1;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Interfaces;

with Synapse.Core.Schema_Pattern;
with Synapse.Core.UTF8;

package body Synapse.Core.Regex_Lite.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Ada.Characters.Latin_1.LF;

   type Code_Points is array (Positive range <>) of Natural;

   --  Text from code points; source literals are never used for non-ASCII
   --  text because they are not UTF-8 bytes.
   function U (Items : Code_Points) return String is
      use Ada.Strings.Unbounded;
      Result : Unbounded_String;
   begin
      for CP of Items loop
         Append (Result, UTF8.Encode (CP));
      end loop;
      return To_String (Result);
   end U;

   function Byte (N : Natural) return String
   is [Character'Val (N)];

   procedure Expect
     (Pattern, Text : String; Want : Outcome; Why : String)
   is
      Got : constant Outcome := Search (Pattern, Text);
   begin
      Assert
        (Got = Want,
         Why & ": got " & Got'Image & ", wanted " & Want'Image);
   end Expect;

   procedure Matches (Pattern, Text : String; Why : String) is
   begin
      Expect (Pattern, Text, Matched, Why);
   end Matches;

   procedure Fails (Pattern, Text : String; Why : String) is
   begin
      Expect (Pattern, Text, Not_Matched, Why);
   end Fails;

   ---------------------------------------------------------------------------
   --  The behavior of the byte matcher this one replaces
   ---------------------------------------------------------------------------

   procedure A_Literal_Matches_As_A_Substring (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text : constant String := "## Status" & LF & "Discussing";
   begin
      Matches ("Discussing", Text, "present");
      Fails ("Ready", Text, "absent");
      Matches ("## Status" & LF & "Discussing",
               "# Title" & LF & LF & "## Status" & LF & "Discussing" & LF,
               "a newline in the pattern matches a newline");
   end A_Literal_Matches_As_A_Substring;

   procedure Anchors_Pin_The_Match (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Matches ("^Hello", "Hello world", "leading ^");
      Fails ("^world", "Hello world", "leading ^ not at the start");
      Matches ("world$", "Hello world", "trailing $");
      Fails ("Hello$", "Hello world", "trailing $ not at the end");
      Matches ("^Hello world$", "Hello world", "both");
      Fails ("^Hello$", "Hello world", "both, text longer");
      Matches ("a$b", "a$b", "$ in the middle is a literal");
      Matches ("a^b", "a^b", "^ in the middle is a literal");
   end Anchors_Pin_The_Match;

   procedure Dot_And_Quantifiers_Work (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Matches ("h.llo", "hello", "dot");
      Matches ("h.llo", "hallo", "dot again");
      Fails ("h.llo", "hllo", "dot needs a character");
      Matches ("^.$", "" & LF, "dot matches a newline");
      Matches ("ab*c", "ac", "star, none");
      Matches ("ab*c", "abbbbc", "star, many");
      Fails ("ab*c", "abd", "star, wrong text");
      Matches ("ab+c", "abbc", "plus");
      Fails ("ab+c", "ac", "plus needs one");
      Matches ("colou?r", "color", "question, none");
      Matches ("colou?r", "colour", "question, one");
      Fails ("colou?r", "colouur", "question, two");
   end Dot_And_Quantifiers_Work;

   procedure Empty_Pattern_And_Long_Pattern (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Matches ("", "anything", "empty pattern");
      Matches ("", "", "empty pattern, empty text");
      Fails ("^much longer than this$", "short", "pattern longer than text");
      Fails ("a", "", "something in nothing");
   end Empty_Pattern_And_Long_Pattern;

   procedure A_Backslash_Is_An_Ordinary_Character
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Slash : constant String := [Character'Val (92)];
   begin
      Matches ("a" & Slash & "." & "b", "a" & Slash & "xb",
               "backslash is literal, the dot after it a wildcard");
      Fails ("a" & Slash & "." & "b", "a.b", "the backslash must be there");
      Matches ("(a|b){2}", "(a|b){2}", "parentheses and braces are literal");
   end A_Backslash_Is_An_Ordinary_Character;

   ---------------------------------------------------------------------------
   --  Characters, not bytes
   ---------------------------------------------------------------------------

   procedure Dot_Matches_A_Whole_Character (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      E_Acute : constant String := U ([16#E9#]);
      Smile   : constant String := U ([16#1F600#]);
   begin
      Matches ("h.llo", "h" & E_Acute & "llo", "dot is one 2-byte character");
      Matches ("^.$", Smile, "dot is one 4-byte character");
      Fails ("^..$", Smile, "and not two");
   end Dot_Matches_A_Whole_Character;

   procedure Quantifiers_Repeat_A_Whole_Character
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      E_Acute : constant String := U ([16#E9#]);
   begin
      Matches ("^" & E_Acute & "*x$", E_Acute & E_Acute & "x", "star");
      Matches ("^" & E_Acute & "+$", E_Acute & E_Acute & E_Acute, "plus");
      Fails ("^" & E_Acute & "+$", "", "plus needs one");
      Matches ("^a" & E_Acute & "?b$", "ab", "question, none");
      Matches ("^a" & E_Acute & "?b$", "a" & E_Acute & "b", "question, one");
      Fails ("^a" & E_Acute & "?b$", "a" & E_Acute & E_Acute & "b",
             "question, two");
      Matches ("^.*" & E_Acute & "$", "a" & E_Acute & E_Acute,
               "backing off over a 2-byte character");
      Matches ("^.*" & U ([16#1F600#]) & "x$", "a" & U ([16#1F600#]) & "x",
               "backing off over a 4-byte character");
      Fails ("^.*" & U ([16#1F600#]) & "$", "a" & E_Acute & "b",
             "backing off finds nothing");
   end Quantifiers_Repeat_A_Whole_Character;

   procedure A_Malformed_Byte_Is_A_Character_Of_Its_Own
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Stray : constant String := Byte (16#FF#);
      Cut   : constant String := Byte (16#E2#) & Byte (16#82#);
   begin
      Matches ("a.b", "a" & Stray & "b", "a stray byte is one character");
      Matches ("^.$", Stray, "alone too");
      Fails ("a$", "a" & Stray, "it is still there");
      Matches ("^..$", Cut, "a cut sequence is two bytes, two characters");
      Matches ("^.*$", "ok" & Stray & Cut & "ok", "star walks over them");
      Matches ("^a" & Stray & "?b", "ab", "a pattern may hold one");
   end A_Malformed_Byte_Is_A_Character_Of_Its_Own;

   ---------------------------------------------------------------------------
   --  Limits
   ---------------------------------------------------------------------------

   procedure A_Pathological_Pattern_Gives_Up (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect
        ("a*a*a*a*a*a*b", String'(1 .. 40 => 'a'), Too_Complex,
         "nested stars with nothing to find");
      Matches
        ("a*a*a*a*a*a*b", String'(1 .. 40 => 'a') & "b", "and with a b");
   end A_Pathological_Pattern_Gives_Up;

   procedure A_Long_Run_Is_Not_Too_Complex (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Matches ("^a*b$", String'(1 .. 100_000 => 'a') & "b", "a long run");
      Fails ("^a*c$", String'(1 .. 100_000 => 'a') & "b", "and a miss");
   end A_Long_Run_Is_Not_Too_Complex;

   ---------------------------------------------------------------------------
   --  Properties
   ---------------------------------------------------------------------------

   Seed : Interfaces.Unsigned_64 := 20_261_007;

   function Next (Limit : Positive) return Natural is
      use type Interfaces.Unsigned_64;
   begin
      Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural ((Seed / 2**20) mod Interfaces.Unsigned_64 (Limit));
   end Next;

   function Random_Text (Alphabet : String; Longest : Natural) return String is
      Result : String (1 .. Next (Longest + 1));
   begin
      for C of Result loop
         C := Alphabet (Alphabet'First + Next (Alphabet'Length));
      end loop;
      return Result;
   end Random_Text;

   procedure Plain_Patterns_Agree_With_Substring_Search
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for I in 1 .. 4_000 loop
         declare
            Text    : constant String := Random_Text ("abc", 12);
            Pattern : constant String := Random_Text ("abc", 4);
            Want    : constant Outcome :=
              (if Pattern'Length = 0
                 or else Ada.Strings.Fixed.Index (Text, Pattern) > 0
               then Matched
               else Not_Matched);
         begin
            if Search (Pattern, Text) /= Want then
               Assert (False, "case" & I'Image & ": '" & Pattern & "' in '"
                       & Text & "'");
            end if;
         end;
      end loop;
   end Plain_Patterns_Agree_With_Substring_Search;

   --  Where both dialects accept a pattern they must agree.
   procedure The_Two_Dialects_Agree_On_Their_Common_Subset
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      use type Schema_Pattern.Fault;
      Agreed : Natural := 0;
   begin
      for I in 1 .. 20_000 loop
         declare
            Pattern : constant String := Random_Text ("ab.*+?^$", 7);
            Text    : constant String := Random_Text ("abc" & LF, 10);
         begin
            if Schema_Pattern.Validate (Pattern) = Schema_Pattern.None then
               Agreed := Agreed + 1;
               if Schema_Pattern.Search (Pattern, Text)
                 /= Search (Pattern, Text)
               then
                  Assert (False, "case" & I'Image & ": '" & Pattern
                          & "' on '" & Text & "'");
               end if;
            end if;
         end;
      end loop;
      Assert (Agreed > 2_000, "enough patterns were comparable");
   end The_Two_Dialects_Agree_On_Their_Common_Subset;

   procedure Random_Input_Never_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Bytes : String (1 .. 256);
   begin
      for I in Bytes'Range loop
         Bytes (I) := Character'Val (I - 1);
      end loop;
      for I in 1 .. 20_000 loop
         declare
            Pattern : constant String := Random_Text (Bytes, 8);
            Text    : constant String := Random_Text (Bytes, 24);
         begin
            declare
               Ignored : constant Outcome := Search (Pattern, Text);
            begin
               null;
            end;
         exception
            when E : others =>
               Assert (False, "raised " & Ada.Exceptions.Exception_Name (E));
         end;
      end loop;
   end Random_Input_Never_Raises;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Regex_Lite");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Literal_Matches_As_A_Substring'Access,
         "A literal matches as a substring");
      Register_Routine
        (T, Anchors_Pin_The_Match'Access, "Anchors pin the match");
      Register_Routine
        (T, Dot_And_Quantifiers_Work'Access, "Dot and quantifiers work");
      Register_Routine
        (T, Empty_Pattern_And_Long_Pattern'Access,
         "Empty pattern and long pattern");
      Register_Routine
        (T, A_Backslash_Is_An_Ordinary_Character'Access,
         "A backslash is an ordinary character");
      Register_Routine
        (T, Dot_Matches_A_Whole_Character'Access,
         "Dot matches a whole character");
      Register_Routine
        (T, Quantifiers_Repeat_A_Whole_Character'Access,
         "Quantifiers repeat a whole character");
      Register_Routine
        (T, A_Malformed_Byte_Is_A_Character_Of_Its_Own'Access,
         "A malformed byte is a character of its own");
      Register_Routine
        (T, A_Pathological_Pattern_Gives_Up'Access,
         "A pathological pattern gives up");
      Register_Routine
        (T, A_Long_Run_Is_Not_Too_Complex'Access,
         "A long run is not too complex");
      Register_Routine
        (T, Plain_Patterns_Agree_With_Substring_Search'Access,
         "Plain patterns agree with substring search");
      Register_Routine
        (T, The_Two_Dialects_Agree_On_Their_Common_Subset'Access,
         "The two dialects agree on their common subset");
      Register_Routine
        (T, Random_Input_Never_Raises'Access, "Random input never raises");
   end Register_Tests;

end Synapse.Core.Regex_Lite.Tests;
