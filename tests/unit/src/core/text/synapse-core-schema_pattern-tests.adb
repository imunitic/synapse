with Ada.Characters.Latin_1;
with Ada.Exceptions;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Interfaces;

with Synapse.Core.UTF8;

package body Synapse.Core.Schema_Pattern.Tests is

   use AUnit.Assertions;
   use type Regex_Lite.Outcome;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Ada.Characters.Latin_1.LF;

   Slash : constant String := [Character'Val (92)];

   type Code_Points is array (Positive range <>) of Natural;

   function U (Items : Code_Points) return String is
      use Ada.Strings.Unbounded;
      Result : Unbounded_String;
   begin
      for CP of Items loop
         Append (Result, UTF8.Encode (CP));
      end loop;
      return To_String (Result);
   end U;

   function Matches (Pattern, Text : String) return Boolean is
   begin
      Assert (Validate (Pattern) = None, "pattern is valid: " & Pattern);
      return Search (Pattern, Text) = Regex_Lite.Matched;
   end Matches;

   procedure Is_Fault (Pattern : String; Want : Fault) is
      Got : constant Fault := Validate (Pattern);
   begin
      Assert
        (Got = Want,
         "'" & Pattern & "' gave " & Got'Image & ", wanted " & Want'Image);
   end Is_Fault;

   ---------------------------------------------------------------------------
   --  The patterns note schemas actually use
   ---------------------------------------------------------------------------

   procedure Matches_Schema_Id_Patterns (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Id : constant String := "^[a-z][a-z0-9-]*-[0-9]{3,}$";
   begin
      Assert (Matches (Id, "sb-081"), "short id");
      Assert (Matches (Id, "synapse-bard-0012"), "id with a longer prefix");
      Assert (not Matches (Id, "SB-081"), "upper case");
      Assert (not Matches (Id, "sb-81"), "too few digits");
   end Matches_Schema_Id_Patterns;

   procedure Matches_The_Backlink_Pattern (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Backlink : constant String :=
        "^> Compiled task: " & Slash & "[" & Slash & "[[^" & Slash & "]]+"
        & Slash & "]" & Slash & "]$";
   begin
      Assert (Matches (Backlink, "> Compiled task: [[Task title]]"),
              "a backlink");
      Assert (not Matches (Backlink, "> Compiled task: Task title"),
              "plain text");
   end Matches_The_Backlink_Pattern;

   procedure Matches_The_Dated_Summary_Pattern (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dash    : constant String := U ([16#2014#]);
      Pattern : constant String :=
        "^[0-9]{4}-[0-9]{2}-[0-9]{2} " & Dash & " .+$";
   begin
      Assert (Matches (Pattern, "2026-08-30 " & Dash & " implementation"),
              "a dated heading with an em dash");
      Assert (not Matches (Pattern, "2026-8-30 " & Dash & " implementation"),
              "a short month");
   end Matches_The_Dated_Summary_Pattern;

   ---------------------------------------------------------------------------
   --  Validation
   ---------------------------------------------------------------------------

   procedure Refuses_Unknown_Escapes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Is_Fault (Slash & "d", Invalid_Escape);
      Is_Fault (Slash & "w", Invalid_Escape);
      Is_Fault (Slash & "s", Invalid_Escape);
      Is_Fault (Slash & "n", Invalid_Escape);
      Is_Fault ("abc" & Slash, Invalid_Escape);
      Is_Fault (Slash & ".", None);
      Is_Fault (Slash & Slash, None);
      Is_Fault (Slash & "(" & Slash & ")" & Slash & "|", None);
   end Refuses_Unknown_Escapes;

   procedure Refuses_Groups_And_Alternation (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Is_Fault ("^(a|b)$", Unsupported_Construct);
      Is_Fault ("a|b", Unsupported_Construct);
      Is_Fault ("(a)", Unsupported_Construct);
      Is_Fault ("a)", Unsupported_Construct);
      Is_Fault ("[(|)]", None);
   end Refuses_Groups_And_Alternation;

   procedure Refuses_Malformed_Classes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Is_Fault ("[]", Empty_Class);
      Is_Fault ("[^]", Empty_Class);
      Is_Fault ("[abc", Unterminated_Class);
      Is_Fault ("[a" & Slash & "]", Unterminated_Class);
      Is_Fault ("[a-z]", None);
      Is_Fault ("[" & Slash & "]]", None);
   end Refuses_Malformed_Classes;

   procedure Refuses_Malformed_Quantifiers (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Is_Fault ("*a", Invalid_Quantifier);
      Is_Fault ("+", Invalid_Quantifier);
      Is_Fault ("a**", Invalid_Quantifier);
      Is_Fault ("a{", Invalid_Quantifier);
      Is_Fault ("a{2", Invalid_Quantifier);
      Is_Fault ("a{2,", Invalid_Quantifier);
      Is_Fault ("a{2,1}", Invalid_Quantifier);
      Is_Fault ("a{x}", Invalid_Quantifier);
      Is_Fault ("a{}", Invalid_Quantifier);
      Is_Fault ("a}", Invalid_Quantifier);
      Is_Fault ("a{99999999999999999999}", Invalid_Quantifier);
      Is_Fault ("a{2}", None);
      Is_Fault ("a{2,}", None);
      Is_Fault ("a{2,5}", None);
      Is_Fault ("a{0}", None);
   end Refuses_Malformed_Quantifiers;

   ---------------------------------------------------------------------------
   --  Matching
   ---------------------------------------------------------------------------

   procedure Matches_Character_Classes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Matches ("^[abc]+$", "cab"), "set");
      Assert (not Matches ("^[abc]+$", "cad"), "set, outside");
      Assert (Matches ("^[a-c]+$", "abcb"), "range");
      Assert (Matches ("^[^a-c]+$", "xyz"), "negated range");
      Assert (not Matches ("^[^a-c]+$", "xbz"), "negated range, inside");
      Assert (Matches ("^[a-]+$", "a-a"), "a trailing dash is a literal");
      Assert (Matches ("^[" & Slash & "]]$", "]"), "an escaped bracket");
      Assert (Matches ("^[" & Slash & "-a]+$", "-a"),
              "an escaped dash is a literal");
      Assert (not Matches ("^[z-a]$", "m"), "a reversed range is empty");
      Assert (not Matches ("^[z-a]$", "z"), "not even its ends");
      Assert (Matches ("^[^" & Slash & "]]+$", "abc"), "negated bracket");
   end Matches_Character_Classes;

   procedure Matches_Counted_Repetition (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Matches ("^a{3}$", "aaa"), "exactly");
      Assert (not Matches ("^a{3}$", "aa"), "exactly, too few");
      Assert (not Matches ("^a{3}$", "aaaa"), "exactly, too many");
      Assert (Matches ("^a{2,}$", "aaaaa"), "at least");
      Assert (not Matches ("^a{2,}$", "a"), "at least, too few");
      Assert (Matches ("^a{1,2}b$", "aab"), "between");
      Assert (not Matches ("^a{1,2}b$", "aaab"), "between, too many");
      Assert (Matches ("^xa{0}y$", "xy"), "none at all");
   end Matches_Counted_Repetition;

   procedure Treats_Misplaced_Anchors_As_Literals
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Matches ("a$b", "a$b"), "$ in the middle");
      Assert (Matches ("a^b", "a^b"), "^ in the middle");
      Assert (Matches ("^a$", "a"), "both anchors");
      Assert (Matches ("a.c", "a" & LF & "c"), "dot matches a newline");
   end Treats_Misplaced_Anchors_As_Literals;

   procedure Works_On_Whole_Characters (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Privet  : constant String :=
        U ([16#43F#, 16#440#, 16#438#, 16#432#, 16#435#, 16#442#]);
      Cyrillic : constant String :=
        "^[" & U ([16#430#]) & "-" & U ([16#44F#]) & "]+$";
      Three   : constant String := U ([16#43F#, 16#440#, 16#438#]);
   begin
      Assert (Matches (Cyrillic, Privet), "a Cyrillic range");
      Assert (not Matches (Cyrillic, "hello"), "and not Latin text");
      Assert (Matches ("^.{3}$", Three), "three characters, six bytes");
      Assert (not Matches ("^.{3}$", U ([16#43F#, 16#440#])),
              "two is not three");
      Assert (Matches ("^[^" & Slash & "]]+$", Privet),
              "a negated class over multi-byte text");
      Assert (Matches ("^" & U ([16#E9#]) & "{2}$", U ([16#E9#, 16#E9#])),
              "a counted multi-byte literal");
      Assert (Matches ("^.*" & U ([16#E9#]) & "$", "a" & U ([16#E9#, 16#E9#])),
              "backing off over a 2-byte character");
      Assert (Matches ("^[^x]+" & U ([16#44F#]) & "$",
                       U ([16#43F#, 16#440#, 16#44F#])),
              "a negated class backs off over Cyrillic");
   end Works_On_Whole_Characters;

   procedure Gives_Up_On_A_Pathological_Pattern
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Pattern : constant String := "a*a*a*a*a*a*b";
   begin
      Assert (Validate (Pattern) = None, "the pattern is valid");
      Assert
        (Search (Pattern, String'(1 .. 40 => 'a')) = Regex_Lite.Too_Complex,
         "and too much work");
   end Gives_Up_On_A_Pathological_Pattern;

   ---------------------------------------------------------------------------
   --  Properties
   ---------------------------------------------------------------------------

   Seed : Interfaces.Unsigned_64 := 20_261_008;

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

   procedure Search_Never_Raises_On_Valid_Patterns
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Alphabet : constant String :=
        "ab.*+?{}[]^$-,0123" & Slash & "()|" & LF;
      Valid    : Natural := 0;
   begin
      for I in 1 .. 30_000 loop
         declare
            Pattern : constant String := Random_Text (Alphabet, 9);
            Text    : constant String :=
              Random_Text ("ab-1" & Slash & "]", 14);
         begin
            if Validate (Pattern) = None then
               Valid := Valid + 1;
               declare
                  Ignored : constant Regex_Lite.Outcome :=
                    Search (Pattern, Text);
               begin
                  null;
               end;
            end if;
         exception
            when E : others =>
               Assert (False, "'" & Pattern & "' raised "
                       & Ada.Exceptions.Exception_Name (E));
         end;
      end loop;
      Assert (Valid > 1_000, "enough valid patterns were generated");
   end Search_Never_Raises_On_Valid_Patterns;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Schema_Pattern");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Matches_Schema_Id_Patterns'Access, "Matches schema id patterns");
      Register_Routine
        (T, Matches_The_Backlink_Pattern'Access,
         "Matches the backlink pattern");
      Register_Routine
        (T, Matches_The_Dated_Summary_Pattern'Access,
         "Matches the dated summary pattern");
      Register_Routine
        (T, Refuses_Unknown_Escapes'Access, "Refuses unknown escapes");
      Register_Routine
        (T, Refuses_Groups_And_Alternation'Access,
         "Refuses groups and alternation");
      Register_Routine
        (T, Refuses_Malformed_Classes'Access, "Refuses malformed classes");
      Register_Routine
        (T, Refuses_Malformed_Quantifiers'Access,
         "Refuses malformed quantifiers");
      Register_Routine
        (T, Matches_Character_Classes'Access, "Matches character classes");
      Register_Routine
        (T, Matches_Counted_Repetition'Access, "Matches counted repetition");
      Register_Routine
        (T, Treats_Misplaced_Anchors_As_Literals'Access,
         "Treats misplaced anchors as literals");
      Register_Routine
        (T, Works_On_Whole_Characters'Access, "Works on whole characters");
      Register_Routine
        (T, Gives_Up_On_A_Pathological_Pattern'Access,
         "Gives up on a pathological pattern");
      Register_Routine
        (T, Search_Never_Raises_On_Valid_Patterns'Access,
         "Search never raises on valid patterns");
   end Register_Tests;

end Synapse.Core.Schema_Pattern.Tests;
