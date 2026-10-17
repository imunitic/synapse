with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Maps;

with Synapse.Core.Rarity;
with Synapse.Core.Words;
with Synapse.Core.Decimal_Image;

package body Synapse.Core.Gate is

   HT : constant Character := Character'Val (9);
   LF : constant Character := Character'Val (10);

   type Term is record
      Word  : Unbounded_String;
      Count : Long_Long_Integer;
   end record;

   function Ranks_Before (A, B : Term) return Boolean is
     (A.Count > B.Count or else (A.Count = B.Count and then A.Word < B.Word));

   package Term_Vectors is new Ada.Containers.Vectors (Positive, Term);
   package Term_Sorting is new Term_Vectors.Generic_Sorting (Ranks_Before);

   package Count_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Natural, Ada.Strings.Hash, "=");

   package Name_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Positive, Ada.Strings.Hash, "=");

   type Cluster is record
      Name  : Unbounded_String;
      Terms : Term_Vectors.Vector;
      --  Word to its position in Terms.
      Index : Name_Maps.Map;
   end record;

   package Cluster_Vectors is new Ada.Containers.Vectors (Positive, Cluster);

   type Parsed is record
      Clusters : Cluster_Vectors.Vector;
      --  Word to how many clusters contain it.
      Doc_Freq : Count_Maps.Map;
   end record;

   --  A count as `parseInt` reads it: an optional plus and digits, anything
   --  else, or a value too large, reading as zero.
   function Count_Of (Text : String) return Long_Long_Integer is
      Trimmed : constant String   :=
        Ada.Strings.Fixed.Trim
          (Text, Ada.Strings.Maps.To_Set (" " & HT & Character'Val (13)),
           Ada.Strings.Maps.To_Set (" " & HT & Character'Val (13)));
      From    : Positive          := Trimmed'First;
      Value   : Long_Long_Integer := 0;
   begin
      if Trimmed'Length > 0 and then Trimmed (Trimmed'First) = '+' then
         From := From + 1;
      end if;
      if From > Trimmed'Last then
         return 0;
      end if;
      for I in From .. Trimmed'Last loop
         if Trimmed (I) not in '0' .. '9' then
            return 0;
         end if;
         declare
            Digit : constant Long_Long_Integer :=
              Character'Pos (Trimmed (I)) - Character'Pos ('0');
         begin
            if Value > (Long_Long_Integer'Last - Digit) / 10 then
               return 0;
            end if;
            Value := Value * 10 + Digit;
         end;
      end loop;
      return Value;
   end Count_Of;

   function Parse_Table (Table : String) return Parsed is
      Result  : Parsed;
      By_Name : Name_Maps.Map;
      Start   : Integer := Table'First;
   begin
      while Start <= Table'Last + 1 loop
         declare
            Stop : Integer := Start;
         begin
            while Stop <= Table'Last and then Table (Stop) /= LF loop
               Stop := Stop + 1;
            end loop;
            declare
               Last : Integer := Stop - 1;
            begin
               while Last >= Start and then Table (Last) = Character'Val (13)
               loop
                  Last := Last - 1;
               end loop;
               declare
                  Line  : constant String  := Table (Start .. Last);
                  Tab_1 : constant Natural :=
                    Ada.Strings.Fixed.Index (Line, "" & HT);
                  Tab_2 : constant Natural :=
                    (if Tab_1 = 0 then 0
                     else Ada.Strings.Fixed.Index (Line, "" & HT, Tab_1 + 1));
               begin
                  if Tab_2 > 0 then
                     declare
                        Name  : constant String            :=
                          Line (Line'First .. Tab_1 - 1);
                        Word  : constant String            :=
                          Line (Tab_1 + 1 .. Tab_2 - 1);
                        Tab_3 : constant Natural           :=
                          Ada.Strings.Fixed.Index (Line, "" & HT, Tab_2 + 1);
                        Count : constant Long_Long_Integer :=
                          Count_Of
                            (Line
                               (Tab_2 + 1 ..
                                    (if Tab_3 = 0 then Line'Last
                                     else Tab_3 - 1)));
                     begin
                        if Name /= "" and then Word /= "" then
                           if not By_Name.Contains (Name) then
                              Result.Clusters.Append
                                (Cluster'
                                   (Name   => To_Unbounded_String (Name),
                                    others => <>));
                              By_Name.Insert
                                (Name, Positive (Result.Clusters.Length));
                           end if;
                           declare
                              Where : constant Positive := By_Name (Name);
                              Item  : Cluster := Result.Clusters (Where);
                           begin
                              if Item.Index.Contains (Word) then
                                 declare
                                    At_Term : constant Positive :=
                                      Item.Index (Word);
                                 begin
                                    if Count > Item.Terms (At_Term).Count then
                                       Item.Terms (At_Term).Count := Count;
                                    end if;
                                 end;
                              else
                                 Item.Terms.Append
                                   (Term'
                                      (Word  => To_Unbounded_String (Word),
                                       Count => Count));
                                 Item.Index.Insert
                                   (Word, Positive (Item.Terms.Length));
                                 if Result.Doc_Freq.Contains (Word) then
                                    Result.Doc_Freq.Replace
                                      (Word, Result.Doc_Freq (Word) + 1);
                                 else
                                    Result.Doc_Freq.Insert (Word, 1);
                                 end if;
                              end if;
                              Result.Clusters.Replace_Element (Where, Item);
                           end;
                        end if;
                     end;
                  end if;
               end;
            end;
            Start := Stop + 1;
         end;
      end loop;
      return Result;
   end Parse_Table;

   --  The N highest-count words, ties broken by name ascending, so a run is
   --  reproducible.
   function Select_Top
     (Terms : Term_Vectors.Vector; N : Natural) return Text_Lists.Vector
   is
      Ranked : Term_Vectors.Vector := Terms;
      Result : Text_Lists.Vector;
   begin
      Term_Sorting.Sort (Ranked);
      for T of Ranked loop
         exit when Natural (Result.Length) >= N;
         Result.Append (T.Word);
      end loop;
      return Result;
   end Select_Top;

   function Doc_Freq_Of (P : Parsed; Word : Unbounded_String) return Natural is
     (if P.Doc_Freq.Contains (To_String (Word)) then
        P.Doc_Freq (To_String (Word))
      else 0);

   function Judge
     (Table : String; Settings : Options := (others => <>))
      return Verdict_Vectors.Vector
   is
      P      : constant Parsed := Parse_Table (Table);
      Result : Verdict_Vectors.Vector;
   begin
      if P.Clusters.Is_Empty then
         return Result;
      end if;
      declare
         Rare_Max : constant Positive :=
           Rarity.Rare_Max (Natural (P.Clusters.Length));
      begin
         for C of P.Clusters loop
            declare
               Top  : constant Text_Lists.Vector :=
                 Select_Top (C.Terms, Settings.Top);
               Rare : Natural                    := 0;
            begin
               for Word of Top loop
                  if Doc_Freq_Of (P, Word) <= Rare_Max then
                     Rare := Rare + 1;
                  end if;
               end loop;
               Result.Append
                 (Verdict'
                    (Cluster => C.Name, Rare => Rare,
                     State   =>
                       (if Rare > 1 then Ok
                        elsif
                          Settings.Unparseable.Contains (To_String (C.Name))
                        then Unparseable
                        else Flagged),
                     Top     => Top));
            end;
         end loop;
      end;
      return Result;
   end Judge;

   function Verdict_Line (V : Verdict) return String is
      Line : Unbounded_String :=
        To_Unbounded_String
          (To_String (V.Cluster) & HT & Decimal_Image.Image (V.Rare) & HT &
           (case V.State is when Ok => "ok", when Flagged => "flagged",
              when Unparseable => "unparseable") &
           HT);
   begin
      for I in 1 .. Natural (V.Top.Length) loop
         if I > 1 then
            Append (Line, " ");
         end if;
         Append (Line, V.Top (I));
      end loop;
      Append (Line, LF);
      return To_String (Line);
   end Verdict_Line;

   function Judge_Distinctiveness
     (Table : String; Settings : Distinctiveness_Options := (others => <>))
      return Row_Vectors.Vector
   is
      P      : constant Parsed  := Parse_Table (Table);
      Docs   : constant Natural := Natural (P.Clusters.Length);
      Result : Row_Vectors.Vector;
   begin
      for C of P.Clusters loop
         declare
            Top   : constant Text_Lists.Vector :=
              Select_Top (C.Terms, Settings.Top);
            Count : Natural                    := 0;
         begin
            for Word of Top loop
               if Words.Distinctiveness
                   (Doc_Freq_Of (P, Word), Docs, Settings.K) >
                 0.5
               then
                  Count := Count + 1;
               end if;
            end loop;
            Result.Append
              (Distinctiveness_Row'
                 (Group      => C.Name, Distinctive => Count,
                  Considered => Natural (Top.Length)));
         end;
      end loop;
      return Result;
   end Judge_Distinctiveness;

   function Distinctiveness_Line (Row : Distinctiveness_Row) return String is
     (To_String (Row.Group) & HT & Decimal_Image.Image (Row.Distinctive) & HT &
      Decimal_Image.Image (Row.Considered) & LF);

end Synapse.Core.Gate;
