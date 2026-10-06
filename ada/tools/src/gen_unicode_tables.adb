--  Regenerates src/core/synapse-core-unicode_tables.ads and .adb from the
--  Unicode Character Database files:
--
--     gen_unicode_tables <ucd-dir> <output-dir> <unicode-version>
--
--  <ucd-dir> holds UnicodeData.txt, CompositionExclusions.txt and
--  CaseFolding.txt (`just ada-ucd` downloads them). The output is a pure
--  function of those files and the version string, written with LF line
--  endings on every platform.

with Ada.Command_Line;
with Ada.Containers.Ordered_Maps;
with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

procedure Gen_Unicode_Tables is

   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;

   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);

   Max_Line : constant := 79;

   package Natural_Vectors is new
     Ada.Containers.Vectors (Positive, Natural);

   package Natural_Sets is new Ada.Containers.Ordered_Sets (Natural);

   package Sequence_Maps is new
     Ada.Containers.Ordered_Maps
       (Key_Type     => Natural,
        Element_Type => Natural_Vectors.Vector,
        "="          => Natural_Vectors."=");

   ----------------------------------------------------------------------
   --  Records
   ----------------------------------------------------------------------

   type Ccc_Entry is record
      CP  : Natural;
      Ccc : Natural;
   end record;

   type Decomp_Entry is record
      CP  : Natural;
      Seq : Natural_Vectors.Vector;
   end record;

   type Compose_Entry is record
      A, B, Composed : Natural;
   end record;

   type Fold_Entry is record
      CP, Folded : Natural;
   end record;

   function "<" (L, R : Ccc_Entry) return Boolean is (L.CP < R.CP);
   function "<" (L, R : Decomp_Entry) return Boolean is (L.CP < R.CP);
   function "<" (L, R : Fold_Entry) return Boolean is (L.CP < R.CP);
   function "<" (L, R : Compose_Entry) return Boolean
   is (L.A < R.A or else (L.A = R.A and then L.B < R.B));

   package Ccc_Vectors is new Ada.Containers.Vectors (Positive, Ccc_Entry);
   package Decomp_Vectors is new
     Ada.Containers.Vectors (Positive, Decomp_Entry);
   package Compose_Vectors is new
     Ada.Containers.Vectors (Positive, Compose_Entry);
   package Fold_Vectors is new Ada.Containers.Vectors (Positive, Fold_Entry);

   package Ccc_Sorting is new Ccc_Vectors.Generic_Sorting;
   package Decomp_Sorting is new Decomp_Vectors.Generic_Sorting;
   package Compose_Sorting is new Compose_Vectors.Generic_Sorting;
   package Fold_Sorting is new Fold_Vectors.Generic_Sorting;

   ----------------------------------------------------------------------
   --  Text helpers
   ----------------------------------------------------------------------

   function Trim (S : String) return String
   is (Ada.Strings.Fixed.Trim (S, Ada.Strings.Both));

   --  Hexadecimal number; False when S is not one.
   function Parse_Hex (S : String; Value : out Natural) return Boolean is
      T : constant String := Trim (S);
   begin
      Value := 0;
      if T'Length = 0 then
         return False;
      end if;
      for C of T loop
         declare
            Digit : Natural;
         begin
            case C is
               when '0' .. '9' =>
                  Digit := Character'Pos (C) - Character'Pos ('0');

               when 'A' .. 'F' =>
                  Digit := Character'Pos (C) - Character'Pos ('A') + 10;

               when 'a' .. 'f' =>
                  Digit := Character'Pos (C) - Character'Pos ('a') + 10;

               when others =>
                  return False;
            end case;
            if Value > 16#10_FFFF# then
               return False;
            end if;
            Value := Value * 16 + Digit;
         end;
      end loop;
      return Value <= 16#10_FFFF#;
   end Parse_Hex;

   --  The N-th (0-based) ';'-separated field of Line, trimmed; the empty
   --  string when the line has fewer fields.
   function Field (Line : String; N : Natural) return String is
      Start : Positive := Line'First;
      Index : Natural := 0;
   begin
      for I in Line'Range loop
         if Line (I) = ';' then
            if Index = N then
               return Trim (Line (Start .. I - 1));
            end if;
            Index := Index + 1;
            Start := I + 1;
         end if;
      end loop;
      return (if Index = N then Trim (Line (Start .. Line'Last)) else "");
   end Field;

   procedure For_Each_Line
     (Path : String; Process : not null access procedure (Line : String))
   is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Raw : constant String := Ada.Text_IO.Get_Line (File);
            Last : constant Natural :=
              (if Raw'Length > 0 and then Raw (Raw'Last) = CR
               then Raw'Last - 1
               else Raw'Last);
         begin
            Process (Raw (Raw'First .. Last));
         end;
      end loop;
      Ada.Text_IO.Close (File);
   end For_Each_Line;

   ----------------------------------------------------------------------
   --  Parsing
   ----------------------------------------------------------------------

   Ccc_List     : Ccc_Vectors.Vector;
   Decomp_List  : Decomp_Vectors.Vector;
   Exclusions   : Natural_Sets.Set;
   Non_Starters : Natural_Sets.Set;
   Compose_List : Compose_Vectors.Vector;
   Fold_List    : Fold_Vectors.Vector;

   --  UnicodeData.txt fields: code point; name; category; combining class;
   --  bidi class; decomposition. A decomposition starting with '<' is a
   --  compatibility mapping, not the canonical one NFC uses.
   procedure Unicode_Data_Line (Line : String) is
      CP, Ccc, Item : Natural;
   begin
      if Line'Length = 0 or else not Parse_Hex (Field (Line, 0), CP) then
         return;
      end if;

      declare
         Ccc_Text : constant String := Field (Line, 3);
      begin
         Ccc := (if Ccc_Text'Length > 0 then Natural'Value (Ccc_Text) else 0);
      end;
      if Ccc /= 0 then
         Ccc_List.Append (Ccc_Entry'(CP => CP, Ccc => Ccc));
      end if;

      declare
         Text : constant String := Field (Line, 5);
         Seq  : Natural_Vectors.Vector;
         Pos  : Natural := Text'First;
      begin
         if Text'Length = 0 or else Text (Text'First) = '<' then
            return;
         end if;
         while Pos <= Text'Last loop
            declare
               Stop : Natural := Pos;
            begin
               while Stop <= Text'Last and then Text (Stop) /= ' ' loop
                  Stop := Stop + 1;
               end loop;
               if Stop > Pos and then Parse_Hex (Text (Pos .. Stop - 1), Item)
               then
                  Seq.Append (Item);
               end if;
               Pos := Stop + 1;
            end;
         end loop;
         if not Seq.Is_Empty then
            Decomp_List.Append (Decomp_Entry'(CP => CP, Seq => Seq));
         end if;
      end;
   end Unicode_Data_Line;

   --  CompositionExclusions.txt: one code point per data line, optionally
   --  followed by a '#' comment.
   procedure Exclusion_Line (Line : String) is
      Hash : constant Natural := Ada.Strings.Fixed.Index (Line, "#");
      Data : constant String :=
        (if Hash = 0 then Line else Line (Line'First .. Hash - 1));
      CP   : Natural;
   begin
      if Trim (Data)'Length > 0 and then Parse_Hex (Data, CP) then
         Exclusions.Include (CP);
      end if;
   end Exclusion_Line;

   --  CaseFolding.txt: code point; status; mapping; comment. Only C (common)
   --  and S (simple) entries are simple case folding.
   procedure Case_Folding_Line (Line : String) is
      CP, Folded : Natural;
   begin
      if Line'Length = 0 or else Line (Line'First) = '#' then
         return;
      end if;
      declare
         Status : constant String := Field (Line, 1);
      begin
         if (Status = "C" or else Status = "S")
           and then Parse_Hex (Field (Line, 0), CP)
           and then Parse_Hex (Field (Line, 2), Folded)
         then
            Fold_List.Append (Fold_Entry'(CP => CP, Folded => Folded));
         end if;
      end;
   end Case_Folding_Line;

   --  Replaces every decomposition by its full canonical decomposition, so a
   --  consumer never recurses. Composition pairs are taken from the direct
   --  mappings, before this runs.

   Max_Decomposition : Natural := 0;

   procedure Expand_Decompositions is
      Direct : Sequence_Maps.Map;

      procedure Expand (CP : Natural; Into : in out Natural_Vectors.Vector) is
      begin
         if Direct.Contains (CP) then
            for Item of Direct (CP) loop
               Expand (Item, Into);
            end loop;
         else
            Into.Append (CP);
         end if;
      end Expand;
   begin
      for D of Decomp_List loop
         Direct.Include (D.CP, D.Seq);
      end loop;
      for D of Decomp_List loop
         declare
            Full : Natural_Vectors.Vector;
         begin
            Expand (D.CP, Full);
            D.Seq := Full;
            Max_Decomposition :=
              Natural'Max (Max_Decomposition, Natural (Full.Length));
         end;
      end loop;
   end Expand_Decompositions;

   ----------------------------------------------------------------------
   --  Output
   ----------------------------------------------------------------------

   Output : Unbounded_String;

   procedure Put (S : String) is
   begin
      Append (Output, S);
   end Put;

   procedure Put_Line (S : String := "") is
   begin
      Append (Output, S);
      Append (Output, LF);
   end Put_Line;

   function Img (N : Natural) return String
   is (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));

   --  Writes `(Entry)` items separated by ", " one per line; Last_Item says
   --  whether to close the aggregate.
   procedure Close_Table (Last : Boolean) is
   begin
      Put_Line (if Last then "];" else ",");
   end Close_Table;

   Spec_Text : Unbounded_String;
   Body_Text : Unbounded_String;

   procedure Emit_Header (Version : String) is
   begin
      Put_Line ("--  Generated by tools/gen_unicode_tables from the Unicode "
                & "Character Database");
      Put_Line ("--  (UnicodeData.txt, CompositionExclusions.txt, "
                & "CaseFolding.txt),");
      Put_Line ("--  version " & Version & ".");
      Put_Line ("--  Do not edit by hand; regenerate with "
                & "`just ada-gen-unicode`.");
      Put_Line;
   end Emit_Header;

   --  The specification: types, sizes and accessors. The data itself lives in
   --  the body, outside SPARK, so provers never see the table contents.
   procedure Emit_Spec (Version : String) is
      Flat_Count : Natural := 0;
   begin
      for D of Decomp_List loop
         Flat_Count := Flat_Count + Natural (D.Seq.Length);
      end loop;

      Emit_Header (Version);
      Put_Line ("with Synapse.Core.UTF8;");
      Put_Line;
      Put_Line ("package Synapse.Core.Unicode_Tables with SPARK_Mode is");
      Put_Line;
      Put_Line
        ("   Unicode_Version : constant String := """ & Version & """;");
      Put_Line;
      Put_Line ("   subtype Code_Point is UTF8.Code_Point;");
      Put_Line ("   Max_Decomposition : constant := " & Img (Max_Decomposition)
                & ";");
      Put_Line ("   subtype Combining_Class is Natural range 1 .. 254;");
      Put_Line;
      Put_Line ("   Ccc_Count      : constant := "
                & Img (Natural (Ccc_List.Length)) & ";");
      Put_Line ("   Decomp_Count   : constant := "
                & Img (Natural (Decomp_List.Length)) & ";");
      Put_Line
        ("   Decomp_Data_Count : constant := " & Img (Flat_Count) & ";");
      Put_Line ("   Compose_Count  : constant := "
                & Img (Natural (Compose_List.Length)) & ";");
      Put_Line ("   Fold_Count     : constant := "
                & Img (Natural (Fold_List.Length)) & ";");
      Put_Line;
      Put_Line ("   type Ccc_Entry is record");
      Put_Line ("      CP  : Code_Point;");
      Put_Line ("      Ccc : Combining_Class;");
      Put_Line ("   end record;");
      Put_Line;
      Put_Line ("   --  First and Length index Decomp_Item: the entry's full "
                & "canonical");
      Put_Line ("   --  decomposition.");
      Put_Line ("   type Decomp_Entry is record");
      Put_Line ("      CP     : Code_Point;");
      Put_Line ("      First  : Positive;");
      Put_Line ("      Length : Positive range 1 .. Max_Decomposition;");
      Put_Line ("   end record;");
      Put_Line;
      Put_Line ("   type Compose_Entry is record");
      Put_Line ("      A, B, Composed : Code_Point;");
      Put_Line ("   end record;");
      Put_Line;
      Put_Line ("   type Fold_Entry is record");
      Put_Line ("      CP, Folded : Code_Point;");
      Put_Line ("   end record;");
      Put_Line;
      Put_Line ("   --  Non-zero canonical combining classes, sorted by CP.");
      Put_Line ("   function Ccc (I : Positive) return Ccc_Entry");
      Put_Line ("   with Pre => I <= Ccc_Count;");
      Put_Line;
      Put_Line ("   --  Full canonical decompositions, sorted by CP.");
      Put_Line ("   function Decomp (I : Positive) return Decomp_Entry");
      Put_Line ("   with Pre => I <= Decomp_Count;");
      Put_Line;
      Put_Line ("   --  The decompositions' code points, concatenated.");
      Put_Line ("   function Decomp_Item (I : Positive) return Code_Point");
      Put_Line ("   with Pre => I <= Decomp_Data_Count;");
      Put_Line;
      Put_Line ("   --  Primary composites, sorted by (A, B).");
      Put_Line ("   function Compose (I : Positive) return Compose_Entry");
      Put_Line ("   with Pre => I <= Compose_Count;");
      Put_Line;
      Put_Line ("   --  Simple case folding (status C and S), sorted by CP.");
      Put_Line ("   function Fold (I : Positive) return Fold_Entry");
      Put_Line ("   with Pre => I <= Fold_Count;");
      Put_Line;
      Put_Line ("end Synapse.Core.Unicode_Tables;");
   end Emit_Spec;

   procedure Emit_Body (Version : String) is
      Flat   : Natural_Vectors.Vector;
      Column : Natural;
   begin
      Emit_Header (Version);
      Put_Line ("package body Synapse.Core.Unicode_Tables");
      Put_Line ("with SPARK_Mode => Off is");
      Put_Line;

      Put_Line
        ("   Ccc_Table : constant array (1 .. Ccc_Count) of Ccc_Entry :=");
      Put ("     [");
      for I in Ccc_List.First_Index .. Ccc_List.Last_Index loop
         declare
            E : constant Ccc_Entry := Ccc_List (I);
         begin
            if I /= Ccc_List.First_Index then
               Put ("      ");
            end if;
            Put ("(" & Img (E.CP) & ", " & Img (E.Ccc) & ")");
            Close_Table (I = Ccc_List.Last_Index);
         end;
      end loop;
      Put_Line;

      for D of Decomp_List loop
         for C of D.Seq loop
            Flat.Append (C);
         end loop;
      end loop;

      Put_Line ("   Decomp_Table :");
      Put_Line ("     constant array (1 .. Decomp_Count) of Decomp_Entry :=");
      Put ("     [");
      declare
         Next : Positive := 1;
      begin
         for I in Decomp_List.First_Index .. Decomp_List.Last_Index loop
            declare
               E : constant Decomp_Entry := Decomp_List (I);
               L : constant Positive := Positive (E.Seq.Length);
            begin
               if I /= Decomp_List.First_Index then
                  Put ("      ");
               end if;
               Put ("(" & Img (E.CP) & ", " & Img (Next) & ", " & Img (L)
                    & ")");
               Close_Table (I = Decomp_List.Last_Index);
               Next := Next + L;
            end;
         end loop;
      end;
      Put_Line;

      Put_Line ("   Decomp_Data :");
      Put_Line
        ("     constant array (1 .. Decomp_Data_Count) of Code_Point :=");
      Put ("     [");
      Column := 6;
      for I in Flat.First_Index .. Flat.Last_Index loop
         declare
            Item : constant String := Img (Flat (I));
         begin
            if I /= Flat.First_Index then
               --  ", Item," must fit on the line, else start a new one.
               if Column + 2 + Item'Length + 1 > Max_Line then
                  Put_Line (",");
                  Put ("      ");
                  Column := 6;
               else
                  Put (", ");
                  Column := Column + 2;
               end if;
            end if;
            Put (Item);
            Column := Column + Item'Length;
            if I = Flat.Last_Index then
               Put_Line ("];");
            end if;
         end;
      end loop;
      Put_Line;

      Put_Line ("   Compose_Table :");
      Put_Line
        ("     constant array (1 .. Compose_Count) of Compose_Entry :=");
      Put ("     [");
      for I in Compose_List.First_Index .. Compose_List.Last_Index loop
         declare
            E : constant Compose_Entry := Compose_List (I);
         begin
            if I /= Compose_List.First_Index then
               Put ("      ");
            end if;
            Put ("(" & Img (E.A) & ", " & Img (E.B) & ", " & Img (E.Composed)
                 & ")");
            Close_Table (I = Compose_List.Last_Index);
         end;
      end loop;
      Put_Line;

      Put_Line
        ("   Fold_Table : constant array (1 .. Fold_Count) of Fold_Entry :=");
      Put ("     [");
      for I in Fold_List.First_Index .. Fold_List.Last_Index loop
         declare
            E : constant Fold_Entry := Fold_List (I);
         begin
            if I /= Fold_List.First_Index then
               Put ("      ");
            end if;
            Put ("(" & Img (E.CP) & ", " & Img (E.Folded) & ")");
            Close_Table (I = Fold_List.Last_Index);
         end;
      end loop;
      Put_Line;

      Put_Line ("   function Ccc (I : Positive) return Ccc_Entry");
      Put_Line ("   is (Ccc_Table (I));");
      Put_Line;
      Put_Line ("   function Decomp (I : Positive) return Decomp_Entry");
      Put_Line ("   is (Decomp_Table (I));");
      Put_Line;
      Put_Line ("   function Decomp_Item (I : Positive) return Code_Point");
      Put_Line ("   is (Decomp_Data (I));");
      Put_Line;
      Put_Line ("   function Compose (I : Positive) return Compose_Entry");
      Put_Line ("   is (Compose_Table (I));");
      Put_Line;
      Put_Line ("   function Fold (I : Positive) return Fold_Entry");
      Put_Line ("   is (Fold_Table (I));");
      Put_Line;
      Put_Line ("end Synapse.Core.Unicode_Tables;");
   end Emit_Body;

   procedure Write_File (Path : String; Content : Unbounded_String) is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Path);
      String'Write (Ada.Streams.Stream_IO.Stream (File), To_String (Content));
      Ada.Streams.Stream_IO.Close (File);
   end Write_File;

begin
   if Ada.Command_Line.Argument_Count /= 3 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "usage: gen_unicode_tables <ucd-dir> <output-dir> "
         & "<unicode-version>");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   declare
      Dir     : constant String := Ada.Command_Line.Argument (1);
      Out_Dir : constant String := Ada.Command_Line.Argument (2);
      Version : constant String := Ada.Command_Line.Argument (3);
   begin
      For_Each_Line (Dir & "/UnicodeData.txt", Unicode_Data_Line'Access);
      For_Each_Line
        (Dir & "/CompositionExclusions.txt", Exclusion_Line'Access);
      For_Each_Line (Dir & "/CaseFolding.txt", Case_Folding_Line'Access);

      --  Full composition exclusion: the listed code points plus every
      --  non-starter decomposition (a composite that is itself a non-starter,
      --  or whose decomposition begins with one). The exclusions file only
      --  mentions those as a comment.
      for E of Ccc_List loop
         Non_Starters.Include (E.CP);
      end loop;

      for D of Decomp_List loop
         if D.Seq.Length = 2
           and then not Exclusions.Contains (D.CP)
           and then not Non_Starters.Contains (D.CP)
           and then not Non_Starters.Contains (D.Seq (1))
         then
            Compose_List.Append
              (Compose_Entry'(A => D.Seq (1), B => D.Seq (2),
                              Composed => D.CP));
         end if;
      end loop;

      Expand_Decompositions;

      Ccc_Sorting.Sort (Ccc_List);
      Decomp_Sorting.Sort (Decomp_List);
      Compose_Sorting.Sort (Compose_List);
      Fold_Sorting.Sort (Fold_List);

      Emit_Spec (Version);
      Spec_Text := Output;
      Output := Null_Unbounded_String;
      Emit_Body (Version);
      Body_Text := Output;

      Write_File (Out_Dir & "/synapse-core-unicode_tables.ads", Spec_Text);
      Write_File (Out_Dir & "/synapse-core-unicode_tables.adb", Body_Text);

      Ada.Text_IO.Put_Line
        ("wrote " & Out_Dir & ":"
         & Ccc_List.Length'Image & " ccc,"
         & Decomp_List.Length'Image & " decompositions,"
         & Compose_List.Length'Image & " compositions,"
         & Fold_List.Length'Image & " case folds");
   end;
end Gen_Unicode_Tables;
