with Ada.Text_IO;

with AUnit.Assertions;
with Synapse.Core.Unicode.Transforms;
with Synapse.Core.Unicode_Tables;

package body Synapse.Core.Unicode.Tests is

   use AUnit.Assertions;
   use Synapse.Core.Unicode.Transforms;

   package Tables renames Unicode_Tables;

   type Code_Points is array (Positive range <>) of Code_Point;

   --  Text from code points. Source literals are never used for non-ASCII
   --  text: under -gnatW8 they are Latin-1 `String`s, not UTF-8 bytes.
   function U (Items : Code_Points) return String is
      Result : String (1 .. 4 * Items'Length);
      Last   : Natural := 0;
   begin
      for CP of Items loop
         declare
            Encoded : constant String := UTF8.Encode (CP);
         begin
            Result (Last + 1 .. Last + Encoded'Length) := Encoded;
            Last := Last + Encoded'Length;
         end;
      end loop;
      return Result (1 .. Last);
   end U;

   Moskva_Upper : constant String :=
     U ([16#41C#, 16#41E#, 16#421#, 16#41A#, 16#412#, 16#410#]);
   Moskva_Title : constant String :=
     U ([16#41C#, 16#43E#, 16#441#, 16#43A#, 16#432#, 16#430#]);
   Moskva_Lower : constant String :=
     U ([16#43C#, 16#43E#, 16#441#, 16#43A#, 16#432#, 16#430#]);
   Kiev         : constant String :=
     U ([16#41A#, 16#438#, 16#435#, 16#432#]);
   Gorod        : constant String :=
     U ([16#433#, 16#43E#, 16#440#, 16#43E#, 16#434#]);
   Reka         : constant String :=
     U ([16#440#, 16#435#, 16#43A#, 16#430#]);

   Kelvin_Sign : constant String := U ([16#212A#]);

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   ---------------------------------------------------------------------------
   --  NFC
   ---------------------------------------------------------------------------

   procedure NFC_Composes_An_Accent (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Normalize_NFC (U ([16#65#, 16#301#])) = U ([16#E9#]),
         "e + combining acute composes to U+00E9");
   end NFC_Composes_An_Accent;

   procedure NFC_Leaves_Precomposed_Text_Alone (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Cafe : constant String := U ([16#63#, 16#61#, 16#66#, 16#E9#]);
   begin
      Assert (Normalize_NFC (Cafe) = Cafe, "already-NFC text is unchanged");
   end NFC_Leaves_Precomposed_Text_Alone;

   procedure NFC_Composes_A_Dakuten (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Normalize_NFC (U ([16#304B#, 16#3099#])) = U ([16#304C#]),
         "ka + combining dakuten composes to ga");
   end NFC_Composes_A_Dakuten;

   procedure NFC_Composes_Hangul (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Normalize_NFC (U ([16#1100#, 16#1161#])) = U ([16#AC00#]),
         "L + V composes to an LV syllable");
      Assert
        (Normalize_NFC (U ([16#1100#, 16#1161#, 16#11A8#])) = U ([16#AC01#]),
         "L + V + T composes to an LVT syllable");
      Assert
        (Normalize_NFC (U ([16#AC01#])) = U ([16#AC01#]),
         "a composed syllable is unchanged");
   end NFC_Composes_Hangul;

   procedure NFC_Orders_Combining_Marks (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      --  q + dot above (class 230) + dot below (class 220): the lower class
      --  sorts first, and neither pair has a precomposed form with q.
      Input    : constant String := U ([16#71#, 16#307#, 16#323#]);
      Expected : constant String := U ([16#71#, 16#323#, 16#307#]);
   begin
      Assert (Normalize_NFC (Input) = Expected, "marks reorder by class");
   end NFC_Orders_Combining_Marks;

   procedure NFC_Returns_Invalid_Input_Unchanged
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bad : constant String := "ab" & Character'Val (16#FF#);
   begin
      Assert (Normalize_NFC (Bad) = Bad, "invalid UTF-8 passes through");
      Assert (Normalize_NFC ("") = "", "empty stays empty");
   end NFC_Returns_Invalid_Input_Unchanged;

   ---------------------------------------------------------------------------
   --  Case folding
   ---------------------------------------------------------------------------

   procedure Eq_Matches_Cyrillic_In_Any_Case (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Eq_Case_Fold (Moskva_Upper, Moskva_Title), "upper = title");
      Assert (not Eq_Case_Fold (Moskva_Title, Kiev), "different words differ");
   end Eq_Matches_Cyrillic_In_Any_Case;

   procedure Eq_Matches_Ascii_In_Any_Case (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Eq_Case_Fold ("Foo", "foo"), "Foo = foo");
      Assert (not Eq_Case_Fold ("Foo", "Bar"), "Foo /= Bar");
      Assert (Eq_Case_Fold ("", ""), "empty = empty");
      Assert (not Eq_Case_Fold ("", "a"), "empty /= a");
   end Eq_Matches_Ascii_In_Any_Case;

   procedure Eq_Is_False_On_Invalid_Utf8 (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Bad : constant String :=
        [Character'Val (16#FF#), Character'Val (16#FE#)];
   begin
      Assert (not Eq_Case_Fold (Bad, "ok"), "invalid vs valid");
      Assert (not Eq_Case_Fold (Bad, Bad), "invalid is unequal to itself");
   end Eq_Is_False_On_Invalid_Utf8;

   procedure Fold_Lowercases_Cyrillic (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Fold (Moskva_Upper) = Moskva_Lower, "upper folds to lower");
   end Fold_Lowercases_Cyrillic;

   procedure Fold_Can_Change_Byte_Length (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Fold (Kelvin_Sign) = "k", "KELVIN SIGN (3 bytes) folds to k");
   end Fold_Can_Change_Byte_Length;

   procedure Fold_Passes_Invalid_Input_Through (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Bad : constant String := "AB" & Character'Val (16#FF#);
   begin
      Assert (Fold (Bad) = Bad, "invalid UTF-8 is not folded");
   end Fold_Passes_Invalid_Input_Through;

   procedure Key_Ignores_Case_And_Composition (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Normalize_Key (U ([16#45#, 16#301#])) = Normalize_Key (U ([16#E9#])),
         "decomposed capital E-acute and e-acute share a key");
   end Key_Ignores_Case_And_Composition;

   ---------------------------------------------------------------------------
   --  Search
   ---------------------------------------------------------------------------

   procedure Find_Locates_A_Cyrillic_Needle (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text : constant String := Gorod & " " & Moskva_Upper & " " & Reka;
      M    : constant Match := Find_Case_Fold (Text, Moskva_Title);
   begin
      Assert (M.Found, "needle found");
      Assert
        (Text (M.Value.First .. M.Value.Last) = Moskva_Upper,
         "range is the match");
   end Find_Locates_A_Cyrillic_Needle;

   procedure Find_Returns_Nothing_Without_A_Match
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Find_Case_Fold (Gorod & " " & Kiev, Moskva_Title).Found,
         "no match");
      Assert (not Find_Case_Fold ("abc", "").Found, "empty needle");
      Assert (not Find_Case_Fold ("", "a").Found, "empty haystack");
      Assert
        (not Find_Case_Fold ("a" & Character'Val (16#FF#), "a").Found,
         "invalid haystack");
   end Find_Returns_Nothing_Without_A_Match;

   procedure Find_Range_Can_Differ_From_Needle_Length
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String := "x" & Kelvin_Sign & "y";
      M    : constant Match := Find_Case_Fold (Text, "k");
   begin
      Assert (M.Found, "k matches KELVIN SIGN");
      Assert
        (M.Value.Last - M.Value.First + 1 = 3, "the matched span is 3 bytes");
      Assert (M.Value.First = 2, "starts after the x");
   end Find_Range_Can_Differ_From_Needle_Length;

   procedure Count_Counts_Every_Occurrence (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text : constant String :=
        Moskva_Title & " " & Moskva_Lower & " " & Moskva_Upper & " " & Kiev;
   begin
      Assert (Count_Case_Fold (Text, Moskva_Lower) = 3, "three occurrences");
      Assert (Count_Case_Fold ("aaaa", "aa") = 2, "non-overlapping");
      Assert (Count_Case_Fold ("anything", "") = 0, "empty needle is zero");
      Assert (Count_Case_Fold ("", "a") = 0, "empty haystack counts zero");
   end Count_Counts_Every_Occurrence;

   procedure Contains_Agrees_With_Find (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Contains_Case_Fold ("Hello World", "WORLD"), "contains");
      Assert (not Contains_Case_Fold ("Hello World", "xyz"), "absent needle");
   end Contains_Agrees_With_Find;

   ---------------------------------------------------------------------------
   --  Per-code-point data
   ---------------------------------------------------------------------------

   procedure Compose_Pair_Matches_Known_Pairs (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      P : constant Composition := Compose_Pair (16#65#, 16#301#);
   begin
      Assert (P.Found and then P.Value = 16#E9#, "e + acute = U+00E9");
      Assert (not Compose_Pair (16#61#, 16#62#).Found, "a + b: no composite");
      Assert
        (Compose_Pair (16#1100#, 16#1161#).Found
         and then Compose_Pair (16#1100#, 16#1161#).Value = 16#AC00#,
         "Hangul L + V");
   end Compose_Pair_Matches_Known_Pairs;

   procedure Combining_Class_Matches_Known_Marks
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Combining_Class (16#61#) = 0, "a is a starter");
      Assert (Combining_Class (16#301#) = 230, "acute is 230");
      Assert (Combining_Class (16#323#) = 220, "dot below is 220");
   end Combining_Class_Matches_Known_Marks;

   procedure Hangul_Decomposes_Algorithmically (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      LV  : constant Decomposition := Decompose (16#AC00#);
      LVT : constant Decomposition := Decompose (16#AC01#);
   begin
      Assert
        (LV.Length = 2 and then LV.Items (1) = 16#1100#
         and then LV.Items (2) = 16#1161#,
         "LV syllable");
      Assert
        (LVT.Length = 3 and then LVT.Items (3) = 16#11A8#, "LVT syllable");
   end Hangul_Decomposes_Algorithmically;

   procedure Tables_Are_Sorted_And_Consistent (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      for I in 2 .. Tables.Ccc_Count loop
         Assert (Tables.Ccc (I - 1).CP < Tables.Ccc (I).CP, "Ccc sorted");
      end loop;

      for I in 2 .. Tables.Fold_Count loop
         Assert (Tables.Fold (I - 1).CP < Tables.Fold (I).CP, "Fold sorted");
      end loop;
      for I in 1 .. Tables.Fold_Count loop
         Assert
           (Simple_Fold (Tables.Fold (I).Folded) = Tables.Fold (I).Folded,
            "folding is idempotent for" & Tables.Fold (I).CP'Image);
      end loop;

      for I in 2 .. Tables.Compose_Count loop
         declare
            Prev : constant Tables.Compose_Entry := Tables.Compose (I - 1);
            Cur  : constant Tables.Compose_Entry := Tables.Compose (I);
         begin
            Assert
              (Prev.A < Cur.A or else (Prev.A = Cur.A and then Prev.B < Cur.B),
               "Compose sorted");
         end;
      end loop;

      for I in 1 .. Tables.Decomp_Count loop
         declare
            E : constant Tables.Decomp_Entry := Tables.Decomp (I);
         begin
            Assert
              (I = 1 or else Tables.Decomp (I - 1).CP < E.CP, "Decomp sorted");
            Assert
              (E.First + E.Length - 1 <= Tables.Decomp_Data_Count,
               "Decomp entry within the decomposition data");
         end;
      end loop;
   end Tables_Are_Sorted_And_Consistent;

   ---------------------------------------------------------------------------
   --  Conformance: Unicode's own NormalizationTest.txt
   ---------------------------------------------------------------------------

   Conformance_File : constant String := "../ucd/NormalizationTest.txt";

   --  A column of the file: space-separated hexadecimal code points.
   function Column (Line : String; N : Natural) return String is
      Start : Positive := Line'First;
      Index : Natural := 0;

      function Decode_Column (Text : String) return String is
         Items : Code_Points (1 .. Text'Length);
         Count : Natural := 0;
         Value : Natural := 0;
         In_Number : Boolean := False;

         procedure Flush is
         begin
            if In_Number then
               Count := Count + 1;
               Items (Count) := Value;
               Value := 0;
               In_Number := False;
            end if;
         end Flush;
      begin
         for C of Text loop
            case C is
               when '0' .. '9' =>
                  Value :=
                    Value * 16 + Character'Pos (C) - Character'Pos ('0');
                  In_Number := True;

               when 'A' .. 'F' =>
                  Value :=
                    Value * 16 + Character'Pos (C) - Character'Pos ('A') + 10;
                  In_Number := True;

               when others =>
                  Flush;
            end case;
         end loop;
         Flush;
         return U (Items (1 .. Count));
      end Decode_Column;
   begin
      for I in Line'Range loop
         if Line (I) = ';' then
            if Index = N then
               return Decode_Column (Line (Start .. I - 1));
            end if;
            Index := Index + 1;
            Start := I + 1;
         end if;
      end loop;
      return "";
   end Column;

   procedure NFC_Conforms_To_The_Unicode_Test_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      File : Ada.Text_IO.File_Type;
      Rows : Natural := 0;
      Line_No : Natural := 0;
      Failure : String (1 .. 80) := [others => ' '];
      Failed  : Boolean := False;

      procedure Fail (Message : String) is
         N : constant Natural := Natural'Min (Failure'Length, Message'Length);
      begin
         if not Failed then
            Failed := True;
            Failure (1 .. N) :=
              Message (Message'First .. Message'First + N - 1);
         end if;
      end Fail;
   begin
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Conformance_File);
      exception
         when Ada.Text_IO.Name_Error =>
            Assert
              (False,
               Conformance_File & " is missing; run `just ada-ucd` first");
            return;
      end;

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            Line_No := Line_No + 1;
            if Line'Length > 0
              and then Line (Line'First) not in '#' | '@'
            then
               declare
                  C1 : constant String := Column (Line, 0);
                  C2 : constant String := Column (Line, 1);
                  C3 : constant String := Column (Line, 2);
                  C4 : constant String := Column (Line, 3);
                  C5 : constant String := Column (Line, 4);
                  Where : constant String := " at line" & Line_No'Image;
               begin
                  Rows := Rows + 1;
                  if Normalize_NFC (C1) /= C2
                    or else Normalize_NFC (C2) /= C2
                    or else Normalize_NFC (C3) /= C2
                  then
                     Fail ("NFC of c1/c2/c3 /= c2" & Where);
                  end if;
                  if Normalize_NFC (C4) /= C4
                    or else Normalize_NFC (C5) /= C4
                  then
                     Fail ("NFC of c4/c5 /= c4" & Where);
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      Assert (not Failed, Failure);
      Assert (Rows > 18_000, "the conformance file was read in full");
   end NFC_Conforms_To_The_Unicode_Test_File;

   procedure Properties_Hold_Over_The_Conformance_Corpus
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      File : Ada.Text_IO.File_Type;
      Line_No : Natural := 0;
      Failure : String (1 .. 80) := [others => ' '];
      Failed  : Boolean := False;

      procedure Fail (Message : String) is
         N : constant Natural := Natural'Min (Failure'Length, Message'Length);
      begin
         if not Failed then
            Failed := True;
            Failure (1 .. N) :=
              Message (Message'First .. Message'First + N - 1);
         end if;
      end Fail;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Conformance_File);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            Line_No := Line_No + 1;
            if Line'Length > 0
              and then Line (Line'First) not in '#' | '@'
            then
               declare
                  C1 : constant String := Column (Line, 0);
                  C2 : constant String := Column (Line, 1);
                  C4 : constant String := Column (Line, 3);
                  Where : constant String := " at line" & Line_No'Image;
               begin
                  if Fold (Fold (C1)) /= Fold (C1) then
                     Fail ("Fold is not idempotent" & Where);
                  end if;
                  if Eq_Case_Fold (C1, C4) /= Eq_Case_Fold (C4, C1) then
                     Fail ("Eq_Case_Fold is not symmetric" & Where);
                  end if;
                  if not Eq_Case_Fold (C1, C1)
                    or else not Eq_Case_Fold (C1, Fold (C1))
                  then
                     Fail ("Eq_Case_Fold is not reflexive" & Where);
                  end if;
                  if Normalize_Key (C1) /= Normalize_Key (C2) then
                     Fail ("Key differs across NFC forms" & Where);
                  end if;
                  if C1'Length > 0
                    and then not Contains_Case_Fold (C1, C1)
                  then
                     Fail ("text does not contain itself" & Where);
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      Assert (not Failed, Failure);
   end Properties_Hold_Over_The_Conformance_Corpus;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Unicode");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, NFC_Composes_An_Accent'Access, "NFC composes an accent");
      Register_Routine
        (T, NFC_Leaves_Precomposed_Text_Alone'Access,
         "NFC leaves precomposed text alone");
      Register_Routine
        (T, NFC_Composes_A_Dakuten'Access, "NFC composes a dakuten");
      Register_Routine (T, NFC_Composes_Hangul'Access, "NFC composes Hangul");
      Register_Routine
        (T, NFC_Orders_Combining_Marks'Access, "NFC orders combining marks");
      Register_Routine
        (T, NFC_Returns_Invalid_Input_Unchanged'Access,
         "NFC returns invalid input unchanged");
      Register_Routine
        (T, Eq_Matches_Cyrillic_In_Any_Case'Access,
         "Eq matches Cyrillic in any case");
      Register_Routine
        (T, Eq_Matches_Ascii_In_Any_Case'Access,
         "Eq matches ASCII in any case");
      Register_Routine
        (T, Eq_Is_False_On_Invalid_Utf8'Access,
         "Eq is false on invalid UTF-8");
      Register_Routine
        (T, Fold_Lowercases_Cyrillic'Access, "Fold lowercases Cyrillic");
      Register_Routine
        (T, Fold_Can_Change_Byte_Length'Access, "Fold can change byte length");
      Register_Routine
        (T, Fold_Passes_Invalid_Input_Through'Access,
         "Fold passes invalid input through");
      Register_Routine
        (T, Key_Ignores_Case_And_Composition'Access,
         "Key ignores case and composition");
      Register_Routine
        (T, Find_Locates_A_Cyrillic_Needle'Access,
         "Find locates a Cyrillic needle");
      Register_Routine
        (T, Find_Returns_Nothing_Without_A_Match'Access,
         "Find returns nothing without a match");
      Register_Routine
        (T, Find_Range_Can_Differ_From_Needle_Length'Access,
         "Find range can differ from needle length");
      Register_Routine
        (T, Count_Counts_Every_Occurrence'Access,
         "Count counts every occurrence");
      Register_Routine
        (T, Contains_Agrees_With_Find'Access, "Contains agrees with Find");
      Register_Routine
        (T, Compose_Pair_Matches_Known_Pairs'Access,
         "Compose_Pair matches known pairs");
      Register_Routine
        (T, Combining_Class_Matches_Known_Marks'Access,
         "Combining_Class matches known marks");
      Register_Routine
        (T, Hangul_Decomposes_Algorithmically'Access,
         "Hangul decomposes algorithmically");
      Register_Routine
        (T, Tables_Are_Sorted_And_Consistent'Access,
         "Tables are sorted and consistent");
      Register_Routine
        (T, NFC_Conforms_To_The_Unicode_Test_File'Access,
         "NFC conforms to NormalizationTest.txt");
      Register_Routine
        (T, Properties_Hold_Over_The_Conformance_Corpus'Access,
         "Properties hold over the conformance corpus");
   end Register_Tests;

end Synapse.Core.Unicode.Tests;
