with AUnit.Assertions;

with Interfaces;

package body Synapse.Core.Note_Text.Tests is

   use AUnit.Assertions;
   use type Interfaces.Unsigned_64;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Stem (Path : String) return String is
      S : constant Span := Filename_Stem (Path);
   begin
      return Path (Path'First + S.First .. Path'First + S.Stop - 1);
   end Stem;

   function Kept (Raw : String) return String
   is (Raw (Raw'First .. Raw'First + Strip_Trailing_Comment (Raw) - 1));

   function Decimal (Raw : String) return String is
      Valid : Boolean;
      Value : Long_Long_Integer;
   begin
      Parse_Decimal (Raw, Valid, Value);
      return (if Valid then Long_Long_Integer'Image (Value) else "invalid");
   end Decimal;

   function Instant (Value : String) return Long_Long_Integer is
      Valid   : Boolean;
      Seconds : Long_Long_Integer;
   begin
      Parse_Instant_Seconds (Value, Valid, Seconds);
      Assert (Valid, "valid: " & Value);
      return Seconds;
   end Instant;

   function Title (Line : String) return String is
      Level : constant Natural := Heading_Level (Line);
   begin
      Assert (Level > 0, "a heading: " & Line);
      declare
         S : constant Span := Heading_Title (Line, Level);
      begin
         return Line (Line'First + S.First .. Line'First + S.Stop - 1);
      end;
   end Title;

   ---------------------------------------------------------------------------

   procedure Stems_Drop_Directories_And_The_Suffix
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Stem ("tasks/synapse/X.md") = "X", "posix path");
      Assert (Stem ("tasks\synapse\X.md") = "X", "windows path");
      Assert (Stem ("X.md") = "X", "bare name");
      Assert (Stem ("X") = "X", "no suffix");
      Assert (Stem ("/X.md") = "X", "rooted");
      Assert (Stem ("a.b.md") = "a.b", "inner dot");
      Assert (Stem ("x.md.md") = "x.md", "only the last suffix");
      Assert (Stem ("a.mdx") = "a.mdx", "not a suffix");
      Assert (Stem (".md") = "", "only the suffix");
      Assert (Stem ("dir/") = "", "trailing separator");
      Assert (Stem ("") = "", "empty");
      Assert (Stem ("a/b\c.md") = "c", "mixed separators");
   end Stems_Drop_Directories_And_The_Suffix;

   procedure Comments_Start_Outside_Quotes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Kept ("a # c") = "a ", "after a blank");
      Assert (Kept ("# c") = "", "at the start");
      Assert (Kept ("a#b") = "a#b", "inside a word");
      Assert (Kept ("'a # b' # c") = "'a # b' ", "inside single quotes");
      Assert (Kept ("""a # b"" # c") = """a # b"" ", "inside double quotes");
      Assert (Kept ("""a # b") = """a # b", "an open quote hides it");
      Assert (Kept ("it's # c") = "it's # c", "an apostrophe opens a quote");
      Assert (Kept ("") = "", "empty");
      Assert (Kept ("a" & Character'Val (9) & "#c") = "a" & Character'Val (9),
              "after a tab");
   end Comments_Start_Outside_Quotes;

   procedure Decimals_Must_Fit (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Decimal ("0") = " 0", "zero");
      Assert (Decimal ("-5") = "-5", "negative");
      Assert (Decimal ("0042") = " 42", "leading zeros");
      Assert (Decimal ("9223372036854775807") = " 9223372036854775807",
              "largest");
      Assert (Decimal ("-9223372036854775808") = "-9223372036854775808",
              "smallest");
      Assert (Decimal ("9223372036854775808") = "invalid", "one too large");
      Assert (Decimal ("-9223372036854775809") = "invalid", "one too small");
      Assert (Decimal ("99999999999999999999") = "invalid", "far too large");
      Assert (Decimal ("") = "invalid", "empty");
      Assert (Decimal ("-") = "invalid", "only a sign");
      Assert (Decimal ("+1") = "invalid", "plus sign");
      Assert (Decimal ("1a") = "invalid", "trailing letter");
      Assert (Decimal ("1.5") = "invalid", "fraction");
      Assert (Decimal (" 1") = "invalid", "leading blank");
   end Decimals_Must_Fit;

   procedure Timestamps_Are_Checked_For_Shape_And_Range
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Good (S : String) is
      begin
         Assert (Valid_Timestamp (S), "valid: " & S);
      end Good;

      procedure Bad (S : String) is
      begin
         Assert (not Valid_Timestamp (S), "invalid: " & S);
      end Bad;
   begin
      Good ("2026-09-06T21:29:16Z");
      Good ("2026-09-06T21:29:16+02:00");
      Good ("2026-09-06T21:29:16-05:00");
      Good ("2026-09-06T00:00:00+23:59");
      Good ("2026-02-31T00:00:00Z");  --  shape and ranges, not the calendar
      Bad ("");
      Bad ("not a timestamp");
      Bad ("2026-09-06T21:29:16");
      Bad ("2026-09-06T21:29:16+0200");
      Bad ("2026-09-06T21:29:16+02");
      Bad ("2026-09-06T21:29:16z");
      Bad ("2026-09-06 21:29:16Z");
      Bad ("2026-09-06t21:29:16Z");
      Bad ("2026-13-06T21:29:16Z");
      Bad ("2026-00-06T21:29:16Z");
      Bad ("2026-09-32T21:29:16Z");
      Bad ("2026-09-00T21:29:16Z");
      Bad ("2026-09-06T24:29:16Z");
      Bad ("2026-09-06T21:60:16Z");
      Bad ("2026-09-06T21:29:60Z");
      Bad ("2026-09-06T21:29:16+24:00");
      Bad ("2026-09-06T21:29:16+02:60");
      Bad ("2026-09-06T21:29:16*02:00");
      Bad ("2026-09-06T21:29:16Z ");
      Bad ("202a-09-06T21:29:16Z");
      Bad ("2026/09/06T21:29:16Z");
   end Timestamps_Are_Checked_For_Shape_And_Range;

   procedure Days_Match_Known_Dates (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Days_From_Civil (1970, 1, 1) = 0, "the epoch");
      Assert (Days_From_Civil (1969, 12, 31) = -1, "the day before");
      Assert (Days_From_Civil (2000, 2, 29) = 11_016, "a leap day");
      Assert (Days_From_Civil (2000, 3, 1) = 11_017, "after it");
      Assert (Days_From_Civil (2026, 9, 6) = 20_702, "a recent date");
      Assert (Days_From_Civil (0, 3, 1) = -719_468, "year zero");
      Assert (Days_From_Civil (9999, 12, 31) = 2_932_896, "the last year");
   end Days_Match_Known_Dates;

   --  Counting days one at a time, with month lengths and the leap rule
   --  written out, gives the same numbers as the closed form.
   procedure Days_Agree_With_Counting (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Leap (Y : Integer) return Boolean
      is (Y mod 4 = 0 and then (Y mod 100 /= 0 or else Y mod 400 = 0));

      function Length (Y : Integer; M : Positive) return Positive
      is (case M is
            when 2 => (if Leap (Y) then 29 else 28),
            when 4 | 6 | 9 | 11 => 30,
            when others => 31);

      Y, M, D : Integer;
      Count   : Long_Long_Integer;
   begin
      --  Forward from the epoch.
      Y := 1970; M := 1; D := 1; Count := 0;
      while Y < 2500 loop
         Assert (Days_From_Civil (Y, M, D) = Count,
                 "forward" & Y'Image & M'Image & D'Image);
         Count := Count + 1;
         if D = Length (Y, M) then
            D := 1;
            if M = 12 then
               M := 1;
               Y := Y + 1;
            else
               M := M + 1;
            end if;
         else
            D := D + 1;
         end if;
      end loop;

      --  Backward from the day before.
      Y := 1969; M := 12; D := 31; Count := -1;
      while Y >= 0 loop
         Assert (Days_From_Civil (Y, M, D) = Count,
                 "backward" & Y'Image & M'Image & D'Image);
         Count := Count - 1;
         if D = 1 then
            if M = 1 then
               M := 12;
               Y := Y - 1;
            else
               M := M - 1;
            end if;
            if Y >= 0 then
               D := Length (Y, M);
            end if;
         else
            D := D - 1;
         end if;
      end loop;
   end Days_Agree_With_Counting;

   procedure Instants_Account_For_Offsets (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Instant ("1970-01-01T00:00:00Z") = 0, "the epoch");
      Assert (Instant ("2026-09-07T15:00:00Z") = 1_788_793_200, "a date");
      Assert (Instant ("2026-09-06T21:29:16Z")
              = Instant ("2026-09-06T23:29:16+02:00"),
              "the same instant with an offset");
      Assert (Instant ("2026-09-06T21:29:16Z")
              = Instant ("2026-09-06T16:29:16-05:00"),
              "and a negative one");
      Assert (Instant ("2026-09-06T21:30:16Z")
              = Instant ("2026-09-06T21:29:16Z") + 60, "a minute later");
      Assert (Instant ("2026-09-06T21:29:16+05:30")
              = Instant ("2026-09-06T15:59:16Z"), "a half-hour offset");

      --  The two readings of 01:30 on the night the clocks go back are an
      --  hour apart, and the later offset is the later instant.
      Assert (Instant ("2026-11-01T01:30:00-05:00")
              - Instant ("2026-11-01T01:30:00-04:00") = 3600,
              "the repeated hour");

      declare
         Valid   : Boolean;
         Seconds : Long_Long_Integer;
      begin
         Parse_Instant_Seconds ("not a timestamp", Valid, Seconds);
         Assert (not Valid and then Seconds = 0, "malformed");
         Parse_Instant_Seconds ("2026-13-01T00:00:00Z", Valid, Seconds);
         Assert (not Valid, "out of range");
      end;
   end Instants_Account_For_Offsets;

   procedure Instants_Are_Consistent_For_Random_Values
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      State : Interfaces.Unsigned_64 := 16#9E37_79B9_7F4A_7C15#;

      function Next (Bound : Positive) return Natural is
      begin
         State :=
           State * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
         return
           Natural ((State / 65_536) mod Interfaces.Unsigned_64 (Bound));
      end Next;

      function Two (N : Natural) return String
      is [Character'Val (48 + N / 10), Character'Val (48 + N mod 10)];

      function Stamp
        (Y, Mo, D, H, Mi, S : Natural; Offset : String) return String
      is (Two (Y / 100) & Two (Y mod 100) & "-" & Two (Mo) & "-" & Two (D)
          & "T" & Two (H) & ":" & Two (Mi) & ":" & Two (S) & Offset);

      Previous : Long_Long_Integer := Long_Long_Integer'First;
      Day_Base : Long_Long_Integer;
   begin
      for Round in 1 .. 2_000 loop
         declare
            Y  : constant Natural := 1900 + Next (400);
            Mo : constant Natural := 1 + Next (12);
            D  : constant Natural := 1 + Next (28);
            H  : constant Natural := Next (24);
            Mi : constant Natural := Next (60);
            S  : constant Natural := Next (60);
            OH : constant Natural := Next (24);
            OM : constant Natural := Next (60);
            Plus  : constant Boolean := Next (2) = 0;
            Utc   : constant Long_Long_Integer :=
              Instant (Stamp (Y, Mo, D, H, Mi, S, "Z"));
            Shift : constant Long_Long_Integer :=
              Long_Long_Integer (OH) * 3600 + Long_Long_Integer (OM) * 60;
            Zone  : constant String :=
              (if Plus then "+" else "-") & Two (OH) & ":" & Two (OM);
            Local : constant Long_Long_Integer :=
              Instant (Stamp (Y, Mo, D, H, Mi, S, Zone));
         begin
            Day_Base := Days_From_Civil (Y, Mo, D) * 86_400;
            Assert
              (Utc = Day_Base + Long_Long_Integer (H * 3600 + Mi * 60 + S),
               "UTC is the date and the time of day");
            Assert (Local = Utc + (if Plus then -Shift else Shift),
                    "the offset is subtracted:" & Round'Image);
            Assert (Valid_Timestamp (Stamp (Y, Mo, D, H, Mi, S, Zone)),
                    "generated stamps are valid");
         end;
      end loop;

      --  Later dates give later instants.
      for Y in 1900 .. 2300 loop
         for Mo in 1 .. 12 loop
            declare
               Now : constant Long_Long_Integer :=
                 Instant (Stamp (Y, Mo, 1, 0, 0, 0, "Z"));
            begin
               Assert (Now > Previous, "monotonic");
               Previous := Now;
            end;
         end loop;
      end loop;
   end Instants_Are_Consistent_For_Random_Values;

   procedure Fence_Lines_Are_Recognised (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Fence_Line ("```"), "backticks");
      Assert (Is_Fence_Line ("```text"), "with an info string");
      Assert (Is_Fence_Line ("~~~"), "tildes");
      Assert (Is_Fence_Line ("  ```"), "indented");
      Assert (Is_Fence_Line (Character'Val (9) & "~~~"), "tab indent");
      Assert (not Is_Fence_Line ("``"), "two backticks");
      Assert (not Is_Fence_Line ("~~"), "two tildes");
      Assert (not Is_Fence_Line ("` ``"), "split");
      Assert (not Is_Fence_Line ("a ```"), "not at the start");
      Assert (not Is_Fence_Line (""), "empty");
      Assert (not Is_Fence_Line ("   "), "blank");
   end Fence_Lines_Are_Recognised;

   procedure Headings_Need_A_Space_And_Six_Hashes_At_Most
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Heading_Level ("# A") = 1, "one");
      Assert (Heading_Level ("###### A") = 6, "six");
      Assert (Heading_Level ("####### A") = 0, "seven");
      Assert (Heading_Level ("#A") = 0, "no space");
      Assert (Heading_Level ("#") = 0, "bare");
      Assert (Heading_Level ("# ") = 1, "an empty title");
      Assert (Heading_Level (" # A") = 0, "indented");
      Assert (Heading_Level ("") = 0, "empty");
      Assert (Heading_Level ("A # B") = 0, "not at the start");
      Assert (Title ("# Title") = "Title", "plain");
      Assert (Title ("##   Spaced out   ") = "Spaced out", "trimmed");
      Assert (Title ("# " & Character'Val (9) & "Tab" & Character'Val (9))
              = "Tab", "tabs trimmed");
      Assert (Title ("# ") = "", "empty title");
      Assert (Title ("#    ") = "", "blank title");
      Assert (Title ("# A # B") = "A # B", "inner hash kept");
   end Headings_Need_A_Space_And_Six_Hashes_At_Most;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Note_Text");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Stems_Drop_Directories_And_The_Suffix'Access,
         "Stems drop directories and the suffix");
      Register_Routine
        (T, Comments_Start_Outside_Quotes'Access,
         "Comments start outside quotes");
      Register_Routine
        (T, Decimals_Must_Fit'Access, "Decimals must fit");
      Register_Routine
        (T, Timestamps_Are_Checked_For_Shape_And_Range'Access,
         "Timestamps are checked for shape and range");
      Register_Routine
        (T, Days_Match_Known_Dates'Access, "Days match known dates");
      Register_Routine
        (T, Days_Agree_With_Counting'Access,
         "Days agree with counting one at a time");
      Register_Routine
        (T, Instants_Account_For_Offsets'Access,
         "Instants account for offsets");
      Register_Routine
        (T, Instants_Are_Consistent_For_Random_Values'Access,
         "Instants are consistent for random values");
      Register_Routine
        (T, Fence_Lines_Are_Recognised'Access, "Fence lines are recognised");
      Register_Routine
        (T, Headings_Need_A_Space_And_Six_Hashes_At_Most'Access,
         "Headings need a space and at most six hashes");
   end Register_Tests;

end Synapse.Core.Note_Text.Tests;
