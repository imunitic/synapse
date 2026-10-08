package body Synapse.Core.Unicode with
  SPARK_Mode
is

   package T renames Unicode_Tables;

   ---------------------------------------------------------------------------
   --  Hangul syllables (UAX #15): jamo carry no table entries, so composition
   --  and decomposition are arithmetic.
   ---------------------------------------------------------------------------

   S_Base  : constant := 16#AC00#;
   L_Base  : constant := 16#1100#;
   V_Base  : constant := 16#1161#;
   T_Base  : constant := 16#11A7#;
   L_Count : constant := 19;
   V_Count : constant := 21;
   T_Count : constant := 28;
   N_Count : constant := V_Count * T_Count;
   S_Count : constant := L_Count * N_Count;

   function Is_Hangul_Syllable (CP : Code_Point) return Boolean is
     (CP in S_Base .. S_Base + S_Count - 1);

   ---------------------------------------------------------------------------
   --  Table lookups: binary searches over tables sorted by their key.
   ---------------------------------------------------------------------------

   function Combining_Class (CP : Code_Point) return Natural is
      Lo : Positive := 1;
      Hi : Natural  := T.Ccc_Count + 1;
   begin
      while Lo < Hi loop
         pragma Loop_Invariant (Hi <= T.Ccc_Count + 1);
         pragma Loop_Variant (Decreases => Hi - Lo);
         declare
            Mid : constant Positive   := Lo + (Hi - Lo) / 2;
            Key : constant Code_Point := T.Ccc (Mid).CP;
         begin
            if Key = CP then
               return T.Ccc (Mid).Ccc;
            elsif Key < CP then
               Lo := Mid + 1;
            else
               Hi := Mid;
            end if;
         end;
      end loop;
      return 0;
   end Combining_Class;

   function Simple_Fold (CP : Code_Point) return Code_Point is
      Lo : Positive := 1;
      Hi : Natural  := T.Fold_Count + 1;
   begin
      while Lo < Hi loop
         pragma Loop_Invariant (Hi <= T.Fold_Count + 1);
         pragma Loop_Variant (Decreases => Hi - Lo);
         declare
            Mid : constant Positive   := Lo + (Hi - Lo) / 2;
            Key : constant Code_Point := T.Fold (Mid).CP;
         begin
            if Key = CP then
               return T.Fold (Mid).Folded;
            elsif Key < CP then
               Lo := Mid + 1;
            else
               Hi := Mid;
            end if;
         end;
      end loop;
      return CP;
   end Simple_Fold;

   function Table_Composition (A, B : Code_Point) return Composition is
      Lo : Positive := 1;
      Hi : Natural  := T.Compose_Count + 1;
   begin
      while Lo < Hi loop
         pragma Loop_Invariant (Hi <= T.Compose_Count + 1);
         pragma Loop_Variant (Decreases => Hi - Lo);
         declare
            Mid : constant Positive        := Lo + (Hi - Lo) / 2;
            E   : constant T.Compose_Entry := T.Compose (Mid);
         begin
            if E.A = A and then E.B = B then
               return (Found => True, Value => E.Composed);
            elsif (if E.A /= A then E.A < A else E.B < B) then
               Lo := Mid + 1;
            else
               Hi := Mid;
            end if;
         end;
      end loop;
      return (Found => False);
   end Table_Composition;

   function Compose_Pair (A, B : Code_Point) return Composition is
   begin
      --  Hangul L + V -> LV syllable.
      if A in L_Base .. L_Base + L_Count - 1
        and then B in V_Base .. V_Base + V_Count - 1
      then
         return
           (Found => True,
            Value =>
              S_Base + ((A - L_Base) * V_Count + (B - V_Base)) * T_Count);
      end if;

      --  Hangul LV + T -> LVT syllable.
      if Is_Hangul_Syllable (A) and then (A - S_Base) mod T_Count = 0
        and then B in T_Base + 1 .. T_Base + T_Count - 1
      then
         return (Found => True, Value => A + (B - T_Base));
      end if;

      return Table_Composition (A, B);
   end Compose_Pair;

   function Decompose (CP : Code_Point) return Decomposition is
      Result : Decomposition;
   begin
      if Is_Hangul_Syllable (CP) then
         declare
            Index : constant Natural := CP - S_Base;
            Trail : constant Natural := Index mod T_Count;
         begin
            Result.Items (1) := L_Base + Index / N_Count;
            Result.Items (2) := V_Base + (Index mod N_Count) / T_Count;
            if Trail = 0 then
               Result.Length := 2;
            else
               Result.Items (3) := T_Base + Trail;
               Result.Length    := 3;
            end if;
            return Result;
         end;
      end if;

      declare
         Lo : Positive := 1;
         Hi : Natural  := T.Decomp_Count + 1;
      begin
         while Lo < Hi loop
            pragma Loop_Invariant (Hi <= T.Decomp_Count + 1);
            pragma Loop_Variant (Decreases => Hi - Lo);
            declare
               Mid : constant Positive       := Lo + (Hi - Lo) / 2;
               E   : constant T.Decomp_Entry := T.Decomp (Mid);
            begin
               if E.CP = CP then
                  if E.First <= T.Decomp_Data_Count - E.Length + 1 then
                     Result.Length := E.Length;
                     for K in 1 .. E.Length loop
                        pragma Loop_Invariant
                          (E.First <= T.Decomp_Data_Count - E.Length + 1);
                        Result.Items (K) := T.Decomp_Item (E.First + K - 1);
                     end loop;
                     return Result;
                  end if;
                  exit;
               elsif E.CP < CP then
                  Lo := Mid + 1;
               else
                  Hi := Mid;
               end if;
            end;
         end loop;
      end;

      Result.Items (1) := CP;
      Result.Length    := 1;
      return Result;
   end Decompose;

   ---------------------------------------------------------------------------
   --  Case-fold equality and search: single passes over the UTF-8 bytes.
   ---------------------------------------------------------------------------

   function Eq_Case_Fold (A, B : String) return Boolean is
   begin
      if A'Length = 0 or else B'Length = 0 then
         return A'Length = 0 and then B'Length = 0;
      end if;

      declare
         PA : Positive := A'First;
         PB : Positive := B'First;
      begin
         loop
            pragma Loop_Invariant (PA >= A'First and then PB >= B'First);
            pragma Loop_Variant (Increases => PA);
            if PA > A'Last or else PB > B'Last then
               return PA > A'Last and then PB > B'Last;
            end if;

            declare
               LA : constant Natural := UTF8.Sequence_Length (A, PA);
               LB : constant Natural := UTF8.Sequence_Length (B, PB);
            begin
               if LA = 0 or else LB = 0 then
                  return False;
               end if;
               if Simple_Fold (UTF8.Scalar_At (A, PA)) /=
                 Simple_Fold (UTF8.Scalar_At (B, PB))
               then
                  return False;
               end if;
               PA := PA + LA;
               PB := PB + LB;
            end;
         end loop;
      end;
   end Eq_Case_Fold;

   --  Both strings are valid UTF-8 and Needle is not empty. The first match
   --  starting at or after From, which must lie in Haystack'First ..
   --  Haystack'Last + 1.
   function Find_From
     (Haystack, Needle : String; From : Positive) return Match with
     Pre  =>
      Haystack'Last < Positive'Last and then Needle'Last < Positive'Last
      and then Needle'Length > 0 and then From >= Haystack'First,
     Post =>
      (if Find_From'Result.Found then
         Find_From'Result.Value.First in Haystack'Range
         and then Find_From'Result.Value.Last in Haystack'Range
         and then Find_From'Result.Value.First <= Find_From'Result.Value.Last
         and then Find_From'Result.Value.First >= From);

   function Find_From (Haystack, Needle : String; From : Positive) return Match
   is
      Start : Positive := From;
   begin
      while Start <= Haystack'Last loop
         pragma Loop_Invariant (Start >= From);
         pragma Loop_Invariant (Start in Haystack'Range);
         pragma Loop_Variant (Increases => Start);

         declare
            HP      : Positive := Start;
            NP      : Positive := Needle'First;
            Matched : Boolean  := True;
         begin
            while NP <= Needle'Last loop
               pragma Loop_Invariant (HP >= Start and then NP >= Needle'First);
               pragma Loop_Variant (Increases => NP);
               if HP > Haystack'Last then
                  return (Found => False);
               end if;

               declare
                  LN : constant Natural := UTF8.Sequence_Length (Needle, NP);
                  LH : constant Natural := UTF8.Sequence_Length (Haystack, HP);
               begin
                  if LN = 0 or else LH = 0
                    or else Simple_Fold (UTF8.Scalar_At (Haystack, HP)) /=
                      Simple_Fold (UTF8.Scalar_At (Needle, NP))
                  then
                     Matched := False;
                     exit;
                  end if;
                  NP := NP + LN;
                  HP := HP + LH;
               end;
            end loop;

            if Matched then
               return
                 (Found => True, Value => (First => Start, Last => HP - 1));
            end if;
         end;

         declare
            Step : constant Natural := UTF8.Sequence_Length (Haystack, Start);
         begin
            if Step = 0 then
               return (Found => False);
            end if;
            Start := Start + Step;
         end;
      end loop;
      return (Found => False);
   end Find_From;

   function Searchable (Haystack, Needle : String) return Boolean is
     (Haystack'Length > 0 and then Needle'Length > 0
      and then UTF8.Is_Valid (Haystack) and then UTF8.Is_Valid (Needle)) with
     Pre => Haystack'Last < Positive'Last and then Needle'Last < Positive'Last;

   function Find_Case_Fold (Haystack, Needle : String) return Match is
   begin
      if not Searchable (Haystack, Needle) then
         return (Found => False);
      end if;
      return Find_From (Haystack, Needle, Haystack'First);
   end Find_Case_Fold;

   function Contains_Case_Fold (Haystack, Needle : String) return Boolean is
     (Find_Case_Fold (Haystack, Needle).Found);

   function Count_Case_Fold (Haystack, Needle : String) return Natural is
      Count : Natural := 0;
      Pos   : Positive;
   begin
      if not Searchable (Haystack, Needle) then
         return 0;
      end if;

      Pos := Haystack'First;
      while Pos <= Haystack'Last loop
         pragma Loop_Invariant (Pos >= Haystack'First);
         pragma Loop_Invariant (Count <= Pos - Haystack'First);
         pragma Loop_Variant (Increases => Pos);
         declare
            M : constant Match := Find_From (Haystack, Needle, Pos);
         begin
            exit when not M.Found;
            Count := Count + 1;
            Pos   := M.Value.Last + 1;
         end;
      end loop;
      return Count;
   end Count_Case_Fold;

end Synapse.Core.Unicode;
