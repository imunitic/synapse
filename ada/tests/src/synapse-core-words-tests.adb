with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.UTF8;

package body Synapse.Core.Words.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   type Scalars is array (Positive range <>) of UTF8.Scalar_Value;

   function U (Items : Scalars) return String is
      Result : Unbounded_String;
   begin
      for CP of Items loop
         Append (Result, UTF8.Encode (CP));
      end loop;
      return To_String (Result);
   end U;

   function Joined (Words : Text_Lists.Vector) return String is
      Result : Unbounded_String;
   begin
      for W of Words loop
         if Result /= Null_Unbounded_String then
            Append (Result, "|");
         end if;
         Append (Result, W);
      end loop;
      return To_String (Result);
   end Joined;

   procedure Splits_To (Text, Want : String) is
      Got : constant String := Joined (Split_Words (Text));
   begin
      Assert (Got = Want, "'" & Text & "' -> '" & Got & "', wanted '" & Want
              & "'");
   end Splits_To;

   Stop : Text_Lists.Set;

   procedure Identifiers_Split_At_Capitals_And_Underscores
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Splits_To ("getUserName", "get|user|name");
      Splits_To ("premium_rate_table", "premium|rate|table");
      Splits_To ("getUser_name", "get|user|name");
      Splits_To ("HttpClient", "http|client");
   end Identifiers_Split_At_Capitals_And_Underscores;

   procedure A_Run_Of_Capitals_Stays_With_What_Follows
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Splits_To ("HTTPServer", "httpserver");
      Splits_To ("HTTP", "http");
      Splits_To ("IOError", "ioerror");
   end A_Run_Of_Capitals_Stays_With_What_Follows;

   procedure Digits_Attach_To_The_Word_They_Follow
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Splits_To ("utf8Decoder", "utf8|decoder");
      Splits_To ("base64", "base64");
      Splits_To ("Level2Cache", "level2|cache");
      Splits_To ("2026", "2026");
   end Digits_Attach_To_The_Word_They_Follow;

   procedure Separators_Are_Skipped (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Splits_To ("__init__", "init");
      Splits_To ("a-b-c", "a|b|c");
      Splits_To ("Foo.Bar", "foo|bar");
      Splits_To ("", "");
      Splits_To ("___", "");
      Splits_To ("one two" & Character'Val (10) & "three", "one|two|three");
   end Separators_Are_Skipped;

   procedure A_Run_Of_High_Bytes_Is_One_Word (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Japanese : constant String := U ([16#65E5#, 16#672C#, 16#8A9E#]);
      Moscow   : constant String :=
        U ([16#41C#, 16#43E#, 16#441#, 16#43A#, 16#432#, 16#430#]);
   begin
      Splits_To ("widget " & Japanese, "widget|" & Japanese);
      --  Only ASCII letters are lowercased.
      Splits_To (Moscow, Moscow);
      Splits_To ("a" & Moscow & "B", "a|" & Moscow & "|b");
   end A_Run_Of_High_Bytes_Is_One_Word;

   procedure Keep_Drops_Short_Digit_And_Stop_Words
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Words : Text_Lists.Set;
   begin
      Words.Insert ("with");
      Assert (Keep ("premium", Words), "long enough");
      Assert (not Keep ("get", Words), "three is out");
      Assert (Keep ("name", Words), "four is in");
      Assert (not Keep ("2026", Words), "digits");
      Assert (Keep ("utf8", Words), "digits with letters");
      Assert (not Keep ("with", Words), "a stopword");
      Assert (not Keep ("", Words), "empty");
      Assert (Keep ("with", Stop), "no stopwords");
   end Keep_Drops_Short_Digit_And_Stop_Words;

   procedure Keep_Counts_Characters_Not_Bytes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      --  U+20000 is one character in four bytes.
      Assert (not Keep (U ([16#20000#]), Stop), "one character");
      Assert (Keep (U ([16#65E5#, 16#672C#, 16#8A9E#, 16#5B66#]), Stop),
              "four characters");
      Assert (not Keep (U ([16#65E5#, 16#672C#, 16#8A9E#]), Stop),
              "three characters");
      --  Not valid UTF-8: counted in bytes.
      Assert (Keep (Character'Val (16#FF#) & Character'Val (16#FF#)
                    & Character'Val (16#FF#) & Character'Val (16#FF#), Stop),
              "four bytes of garbage");
   end Keep_Counts_Characters_Not_Bytes;

   procedure Query_Terms_Are_Kept_Once_In_Order (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Words : Text_Lists.Set;
   begin
      Words.Insert ("with");
      Assert (Joined (Query_Terms ("DiskStore search with the Disk", Words))
              = "disk|store|search", "split, filtered, unique");
      Assert (Joined (Query_Terms ("a is of", Words)) = "", "nothing left");
      Assert (Joined (Query_Terms ("", Words)) = "", "empty");
      Assert (Joined (Query_Terms ("store DiskStore store", Words))
              = "store|disk", "first seen order");
   end Query_Terms_Are_Kept_Once_In_Order;

   procedure Distinctiveness_Falls_As_A_Word_Gets_Common
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      function Near (A, B : Long_Float) return Boolean
      is (abs (A - B) < 1.0E-12);
   begin
      Assert (Near (Distinctiveness (0, 100, 20), 1.0), "in no document");
      --  D = max (2, 100 / 20) = 5: half-distinctive at df = 5.
      Assert (Near (Distinctiveness (5, 100, 20), 0.5), "the midpoint");
      Assert (Near (Distinctiveness (100, 100, 20), 5.0 / 105.0),
              "in every document");
      --  A small corpus: D is at least 2.
      Assert (Near (Distinctiveness (2, 10, 20), 0.5), "D is at least two");
      Assert (Near (Distinctiveness (1, 0, 20), 2.0 / 3.0), "no documents");
      Assert (Near (Distinctiveness (3, 100, 0), 100.0 / 103.0),
              "K of zero is one");
      for Df in 1 .. 99 loop
         Assert (Distinctiveness (Df, 100, 20)
                 < Distinctiveness (Df - 1, 100, 20), "strictly decreasing");
      end loop;
   end Distinctiveness_Falls_As_A_Word_Gets_Common;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Words");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Identifiers_Split_At_Capitals_And_Underscores'Access,
         "Identifiers split at capitals and underscores");
      Register_Routine
        (T, A_Run_Of_Capitals_Stays_With_What_Follows'Access,
         "A run of capitals stays with what follows");
      Register_Routine
        (T, Digits_Attach_To_The_Word_They_Follow'Access,
         "Digits attach to the word they follow");
      Register_Routine
        (T, Separators_Are_Skipped'Access, "Separators are skipped");
      Register_Routine
        (T, A_Run_Of_High_Bytes_Is_One_Word'Access,
         "A run of high bytes is one word");
      Register_Routine
        (T, Keep_Drops_Short_Digit_And_Stop_Words'Access,
         "Keep drops short, digit and stop words");
      Register_Routine
        (T, Keep_Counts_Characters_Not_Bytes'Access,
         "Keep counts characters, not bytes");
      Register_Routine
        (T, Query_Terms_Are_Kept_Once_In_Order'Access,
         "Query terms are kept once, in order");
      Register_Routine
        (T, Distinctiveness_Falls_As_A_Word_Gets_Common'Access,
         "Distinctiveness falls as a word gets common");
   end Register_Tests;

end Synapse.Core.Words.Tests;
