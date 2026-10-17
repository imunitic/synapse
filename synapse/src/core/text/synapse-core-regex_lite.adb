with Synapse.Core.UTF8;

package body Synapse.Core.Regex_Lite with SPARK_Mode is

   --  All offsets below are 0-based distances from the string's first byte.

   Unbounded : constant Natural := Natural'Last;

   procedure Atom_At
     (S : String; Off : Natural; Value : out Natural; Width : out Positive)
   with
     Pre  => S'Last < Positive'Last and then Off < S'Length,
     Post => Width <= S'Length - Off
   is
   begin
      UTF8.Decode_Lenient (S, S'First + Off, Value, Width);
   end Atom_At;

   function Atom_Matches (Atom, Value : Natural) return Boolean
   is (Atom = Character'Pos ('.') or else Atom = Value);

   procedure Match_Here
     (P      : String;
      PO     : Natural;
      T      : String;
      TO     : Natural;
      Budget : in out Natural;
      Result : out Outcome)
   with
     Pre                =>
       P'Last < Positive'Last
       and then T'Last < Positive'Last
       and then PO <= P'Length
       and then TO <= T'Length,
     Subprogram_Variant => (Decreases => P'Length - PO, Decreases => 0);

   --  Atom repeated between Min and Max times, then the rest of the pattern
   --  from Rest. Tries the longest run first and backs off one atom at a time.
   procedure Match_Repeat
     (P        : String;
      Rest     : Natural;
      T        : String;
      TO       : Natural;
      Atom     : Natural;
      Min, Max : Natural;
      Budget   : in out Natural;
      Result   : out Outcome)
   with
     Pre                =>
       P'Last < Positive'Last
       and then T'Last < Positive'Last
       and then Rest <= P'Length
       and then TO <= T'Length
       and then Min <= Max,
     Subprogram_Variant => (Decreases => P'Length - Rest, Decreases => 1);

   procedure Match_Repeat
     (P        : String;
      Rest     : Natural;
      T        : String;
      TO       : Natural;
      Atom     : Natural;
      Min, Max : Natural;
      Budget   : in out Natural;
      Result   : out Outcome)
   is
      Count : Natural := 0;
      Stop  : Natural := TO;
   begin
      --  The longest run of matching atoms.
      while Count < Max and then Stop < T'Length loop
         pragma Loop_Invariant (Stop >= TO and then Stop <= T'Length);
         pragma Loop_Invariant (Count <= Stop - TO);
         pragma Loop_Variant (Increases => Stop);
         if Budget = 0 then
            Result := Too_Complex;
            return;
         end if;
         Budget := Budget - 1;
         declare
            Value : Natural;
            Width : Positive;
         begin
            Atom_At (T, Stop, Value, Width);
            exit when not Atom_Matches (Atom, Value);
            Stop := Stop + Width;
            Count := Count + 1;
         end;
      end loop;

      if Count < Min then
         Result := Not_Matched;
         return;
      end if;

      --  Back off until the rest matches.
      loop
         pragma Loop_Invariant (Stop >= TO and then Stop <= T'Length);
         pragma Loop_Invariant (Count >= Min);
         pragma Loop_Variant (Decreases => Count);
         Match_Here (P, Rest, T, Stop, Budget, Result);
         if Result /= Not_Matched or else Count = Min or else Stop = TO then
            return;
         end if;
         if Budget = 0 then
            Result := Too_Complex;
            return;
         end if;
         Budget := Budget - 1;
         --  Count > Min, so an atom of the run precedes Stop.
         Stop :=
           UTF8.Previous_Start (T, T'First + TO, T'First + Stop) - T'First;
         Count := Count - 1;
      end loop;
   end Match_Repeat;

   procedure Match_Here
     (P      : String;
      PO     : Natural;
      T      : String;
      TO     : Natural;
      Budget : in out Natural;
      Result : out Outcome) is
   begin
      if Budget = 0 then
         Result := Too_Complex;
         return;
      end if;
      Budget := Budget - 1;

      if PO = P'Length then
         Result := Matched;
         return;
      end if;
      if P'Length - PO = 1 and then P (P'First + PO) = '$' then
         Result := (if TO = T'Length then Matched else Not_Matched);
         return;
      end if;

      declare
         Atom  : Natural;
         Width : Positive;
      begin
         Atom_At (P, PO, Atom, Width);
         declare
            After : constant Natural := PO + Width;
            Quant : constant Character :=
              (if After < P'Length then P (P'First + After) else ' ');
         begin
            if After < P'Length and then Quant = '*' then
               Match_Repeat
                 (P, After + 1, T, TO, Atom, 0, Unbounded, Budget, Result);
            elsif After < P'Length and then Quant = '+' then
               Match_Repeat
                 (P, After + 1, T, TO, Atom, 1, Unbounded, Budget, Result);
            elsif After < P'Length and then Quant = '?' then
               Match_Repeat
                 (P, After + 1, T, TO, Atom, 0, 1, Budget, Result);
            elsif TO = T'Length then
               Result := Not_Matched;
            else
               declare
                  Value : Natural;
                  Step  : Positive;
               begin
                  Atom_At (T, TO, Value, Step);
                  if Atom_Matches (Atom, Value) then
                     Match_Here (P, After, T, TO + Step, Budget, Result);
                  else
                     Result := Not_Matched;
                  end if;
               end;
            end if;
         end;
      end;
   end Match_Here;

   function Search (Pattern, Text : String) return Outcome is
      Budget   : Natural := Step_Limit;
      Anchored : constant Boolean :=
        Pattern'Length > 0 and then Pattern (Pattern'First) = '^';
      Start    : constant Natural := (if Anchored then 1 else 0);
      Offset   : Natural := 0;
      Result   : Outcome;
   begin
      loop
         pragma Loop_Invariant (Offset <= Text'Length);
         pragma Loop_Variant (Increases => Offset);
         Match_Here (Pattern, Start, Text, Offset, Budget, Result);
         if Result /= Not_Matched then
            return Result;
         end if;
         if Anchored or else Offset >= Text'Length then
            return Not_Matched;
         end if;
         declare
            Value : Natural;
            Width : Positive;
         begin
            Atom_At (Text, Offset, Value, Width);
            Offset := Offset + Width;
         end;
      end loop;
   end Search;

end Synapse.Core.Regex_Lite;
