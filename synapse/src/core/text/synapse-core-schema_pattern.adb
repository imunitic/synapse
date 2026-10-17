with Synapse.Core.UTF8;

package body Synapse.Core.Schema_Pattern with SPARK_Mode is

   use Regex_Lite;

   --  All offsets below are 0-based distances from the string's first byte.

   Unbounded : constant Natural := Natural'Last;

   type Atom_Kind is (Literal_Atom, Any_Atom, Class_Atom);

   type Atom is record
      Kind        : Atom_Kind := Any_Atom;
      Value       : Natural := 0;  --  Literal_Atom
      Class_Start : Natural := 0;  --  Class_Atom: the source between [ and ]
      Class_Stop  : Natural := 0;
      Negated     : Boolean := False;
      Next        : Natural := 0;  --  offset just past the atom
   end record;

   type Quantifier is record
      Min  : Natural := 1;
      Max  : Natural := 1;
      Next : Natural := 0;  --  offset just past the quantifier
   end record;

   procedure Atom_At
     (S : String; Off : Natural; Value : out Natural; Width : out Positive)
   with
     Pre  => S'Last < Positive'Last and then Off < S'Length,
     Post => Width <= S'Length - Off
   is
   begin
      UTF8.Decode_Lenient (S, S'First + Off, Value, Width);
   end Atom_At;

   function Is_Escapable (C : Character) return Boolean
   is (C in '.' | '*' | '+' | '?' | '{' | '}' | '[' | ']' | '^' | '$' | '\'
         | '(' | ')' | '|');

   ---------------------------------------------------------------------------
   --  Parsing
   ---------------------------------------------------------------------------

   procedure Parse_Class
     (P : String; Off : Natural; A : out Atom; Error : out Fault)
   with
     Pre  =>
       P'Last < Positive'Last
       and then Off < P'Length
       and then P (P'First + Off) = '[',
     Post =>
       (if Error = None
        then
          A.Kind = Class_Atom
          and then A.Class_Start > Off
          and then A.Class_Start <= A.Class_Stop
          and then A.Class_Stop < P'Length
          and then A.Next = A.Class_Stop + 1)
   is
      I       : Natural := Off + 1;
      Negated : Boolean := False;
      Escaped : Boolean := False;
   begin
      A := (others => <>);
      Error := None;
      if I < P'Length and then P (P'First + I) = '^' then
         Negated := True;
         I := I + 1;
      end if;

      declare
         Start : constant Natural := I;
      begin
         while I < P'Length loop
            pragma Loop_Invariant (I >= Start and then I < P'Length);
            pragma Loop_Variant (Increases => I);
            if not Escaped and then P (P'First + I) = ']' then
               if I = Start then
                  Error := Empty_Class;
               else
                  A :=
                    (Kind        => Class_Atom,
                     Value       => 0,
                     Class_Start => Start,
                     Class_Stop  => I,
                     Negated     => Negated,
                     Next        => I + 1);
               end if;
               return;
            end if;
            Escaped := not Escaped and then P (P'First + I) = '\';
            I := I + 1;
         end loop;
      end;
      Error := Unterminated_Class;
   end Parse_Class;

   procedure Parse_Atom
     (P : String; Off : Natural; A : out Atom; Error : out Fault)
   with
     Pre  => P'Last < Positive'Last and then Off < P'Length,
     Post =>
       (if Error = None
        then
          A.Next in Off + 1 .. P'Length
          and then (if A.Kind = Class_Atom
                    then
                      A.Class_Start <= A.Class_Stop
                      and then A.Class_Stop < P'Length))
   is
      C : constant Character := P (P'First + Off);
   begin
      A := (others => <>);
      Error := None;
      case C is
         when '\' =>
            if Off + 1 >= P'Length
              or else not Is_Escapable (P (P'First + Off + 1))
            then
               Error := Invalid_Escape;
            else
               A :=
                 (Kind  => Literal_Atom,
                  Value => Character'Pos (P (P'First + Off + 1)),
                  Next  => Off + 2,
                  others => <>);
            end if;

         when '.' =>
            A := (Kind => Any_Atom, Next => Off + 1, others => <>);

         when '[' =>
            Parse_Class (P, Off, A, Error);

         when '*' | '+' | '?' | '{' | '}' =>
            Error := Invalid_Quantifier;

         when others =>
            declare
               Value : Natural;
               Width : Positive;
            begin
               Atom_At (P, Off, Value, Width);
               A :=
                 (Kind  => Literal_Atom,
                  Value => Value,
                  Next  => Off + Width,
                  others => <>);
            end;
      end case;
   end Parse_Atom;

   --  The decimal number at Off, which moves past it.
   procedure Parse_Number
     (P     : String;
      Off   : in out Natural;
      Value : out Natural;
      Error : out Fault)
   with
     Pre  => P'Last < Positive'Last and then Off <= P'Length,
     Post => Off >= Off'Old and then Off <= P'Length
   is
      Start : constant Natural := Off;
   begin
      Value := 0;
      Error := None;
      while Off < P'Length and then P (P'First + Off) in '0' .. '9' loop
         pragma Loop_Invariant (Off >= Start and then Off <= P'Length);
         pragma Loop_Variant (Increases => Off);
         declare
            Digit : constant Natural :=
              Character'Pos (P (P'First + Off)) - Character'Pos ('0');
         begin
            if Value > (Natural'Last - Digit) / 10 then
               Error := Invalid_Quantifier;
               return;
            end if;
            Value := Value * 10 + Digit;
         end;
         Off := Off + 1;
      end loop;
      if Off = Start then
         Error := Invalid_Quantifier;
      end if;
   end Parse_Number;

   --  `{n}`, `{n,}` or `{n,m}` starting at the brace.
   procedure Parse_Counted
     (P : String; Off : Natural; Q : out Quantifier; Error : out Fault)
   with
     Pre  =>
       P'Last < Positive'Last
       and then Off < P'Length
       and then P (P'First + Off) = '{',
     Post =>
       (if Error = None
        then Q.Next in Off + 1 .. P'Length and then Q.Min <= Q.Max)
   is
      I      : Natural := Off + 1;
      Lowest : Natural;
      Number : Natural;
   begin
      Q := (others => <>);
      Parse_Number (P, I, Lowest, Error);
      if Error /= None then
         return;
      end if;
      if I >= P'Length then
         Error := Invalid_Quantifier;
      elsif P (P'First + I) = '}' then
         Q := (Min => Lowest, Max => Lowest, Next => I + 1);
      elsif P (P'First + I) /= ',' then
         Error := Invalid_Quantifier;
      else
         I := I + 1;
         if I >= P'Length then
            Error := Invalid_Quantifier;
         elsif P (P'First + I) = '}' then
            Q := (Min => Lowest, Max => Unbounded, Next => I + 1);
         else
            Parse_Number (P, I, Number, Error);
            if Error /= None then
               return;
            end if;
            if I >= P'Length
              or else P (P'First + I) /= '}'
              or else Number < Lowest
            then
               Error := Invalid_Quantifier;
            else
               Q := (Min => Lowest, Max => Number, Next => I + 1);
            end if;
         end if;
      end if;
   end Parse_Counted;

   procedure Parse_Quantifier
     (P : String; Off : Natural; Q : out Quantifier; Error : out Fault)
   with
     Pre  => P'Last < Positive'Last and then Off <= P'Length,
     Post =>
       (if Error = None
        then Q.Next in Off .. P'Length and then Q.Min <= Q.Max)
   is
   begin
      Error := None;
      Q := (Min => 1, Max => 1, Next => Off);
      if Off < P'Length then
         case P (P'First + Off) is
            when '*' =>
               Q := (Min => 0, Max => Unbounded, Next => Off + 1);

            when '+' =>
               Q := (Min => 1, Max => Unbounded, Next => Off + 1);

            when '?' =>
               Q := (Min => 0, Max => 1, Next => Off + 1);

            when '{' =>
               Parse_Counted (P, Off, Q, Error);

            when others =>
               null;
         end case;
      end if;
   end Parse_Quantifier;

   function Validate (Pattern : String) return Fault is
      I : Natural :=
        (if Pattern'Length > 0 and then Pattern (Pattern'First) = '^'
         then 1
         else 0);
   begin
      while I < Pattern'Length loop
         pragma Loop_Invariant (I < Pattern'Length);
         pragma Loop_Variant (Increases => I);
         if Pattern (Pattern'First + I) = '$' and then I + 1 = Pattern'Length
         then
            return None;
         end if;
         if Pattern (Pattern'First + I) in '(' | ')' | '|' then
            return Unsupported_Construct;
         end if;

         declare
            A     : Atom;
            Error : Fault;
         begin
            Parse_Atom (Pattern, I, A, Error);
            if Error /= None then
               return Error;
            end if;
            declare
               Q : Quantifier;
            begin
               Parse_Quantifier (Pattern, A.Next, Q, Error);
               if Error /= None then
                  return Error;
               end if;
               I := Q.Next;
            end;
         end;
      end loop;
      return None;
   end Validate;

   ---------------------------------------------------------------------------
   --  Matching
   ---------------------------------------------------------------------------

   --  The character at Off inside a class source ending at Stop; a backslash
   --  takes the next character literally. Found is False for a backslash with
   --  nothing after it.
   procedure Class_Char
     (P     : String;
      Stop  : Natural;
      Off   : in out Natural;
      Value : out Natural;
      Found : out Boolean)
   with
     Pre  =>
       P'Last < Positive'Last and then Stop <= P'Length and then Off < Stop,
     Post => Off >= Off'Old and then Off <= Stop
   is
      Width : Positive;
   begin
      Value := 0;
      Found := True;
      if P (P'First + Off) = '\' then
         Off := Off + 1;
         if Off >= Stop then
            Found := False;
            return;
         end if;
      end if;
      Atom_At (P, Off, Value, Width);
      Off := Natural'Min (Off + Width, Stop);
   end Class_Char;

   function Class_Matches
     (P : String; A : Atom; Value : Natural) return Boolean
   with
     Pre =>
       P'Last < Positive'Last
       and then A.Class_Start <= A.Class_Stop
       and then A.Class_Stop <= P'Length
   is
      Stop    : constant Natural := A.Class_Stop;
      I       : Natural := A.Class_Start;
      Matched : Boolean := False;
   begin
      while I < Stop loop
         pragma Loop_Invariant (I >= A.Class_Start and then I <= Stop);
         pragma Loop_Variant (Increases => I);
         declare
            First : Natural;
            Found : Boolean;
            Start : constant Natural := I;
         begin
            Class_Char (P, Stop, I, First, Found);
            if not Found or else I <= Start then
               return False;
            end if;

            if I + 1 < Stop and then P (P'First + I) = '-' then
               I := I + 1;
               declare
                  Last : Natural;
               begin
                  Class_Char (P, Stop, I, Last, Found);
                  if not Found then
                     return False;
                  end if;
                  if First <= Value and then Value <= Last then
                     Matched := True;
                  end if;
               end;
            elsif First = Value then
               Matched := True;
            end if;
         end;
      end loop;
      return (if A.Negated then not Matched else Matched);
   end Class_Matches;

   function Atom_Matches
     (P : String; A : Atom; Value : Natural) return Boolean
   with
     Pre =>
       P'Last < Positive'Last
       and then (if A.Kind = Class_Atom
                 then
                   A.Class_Start <= A.Class_Stop
                   and then A.Class_Stop <= P'Length)
   is
   begin
      case A.Kind is
         when Literal_Atom =>
            return A.Value = Value;

         when Any_Atom =>
            return True;

         when Class_Atom =>
            return Class_Matches (P, A, Value);
      end case;
   end Atom_Matches;

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

   procedure Match_Repeat
     (P        : String;
      Rest     : Natural;
      T        : String;
      TO       : Natural;
      A        : Atom;
      Min, Max : Natural;
      Budget   : in out Natural;
      Result   : out Outcome)
   with
     Pre                =>
       P'Last < Positive'Last
       and then T'Last < Positive'Last
       and then Rest <= P'Length
       and then TO <= T'Length
       and then Min <= Max
       and then (if A.Kind = Class_Atom
                 then
                   A.Class_Start <= A.Class_Stop
                   and then A.Class_Stop <= P'Length),
     Subprogram_Variant => (Decreases => P'Length - Rest, Decreases => 1);

   procedure Match_Repeat
     (P        : String;
      Rest     : Natural;
      T        : String;
      TO       : Natural;
      A        : Atom;
      Min, Max : Natural;
      Budget   : in out Natural;
      Result   : out Outcome)
   is
      Count : Natural := 0;
      Stop  : Natural := TO;
   begin
      while Count < Max and then Stop < T'Length loop
         pragma Loop_Invariant (Stop >= TO and then Stop <= T'Length);
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
            exit when not Atom_Matches (P, A, Value);
            Stop := Stop + Width;
            Count := Count + 1;
         end;
      end loop;

      if Count < Min then
         Result := Not_Matched;
         return;
      end if;

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
         A     : Atom;
         Error : Fault;
      begin
         Parse_Atom (P, PO, A, Error);
         if Error /= None then
            Result := Not_Matched;
            return;
         end if;
         declare
            Q : Quantifier;
         begin
            Parse_Quantifier (P, A.Next, Q, Error);
            if Error /= None then
               Result := Not_Matched;
               return;
            end if;
            Match_Repeat
              (P, Q.Next, T, TO, A, Q.Min, Q.Max, Budget, Result);
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

end Synapse.Core.Schema_Pattern;
