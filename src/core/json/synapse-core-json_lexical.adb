package body Synapse.Core.JSON_Lexical with SPARK_Mode is

   function Skip_Digits (S : String; From : Positive) return Positive is
      I : Positive := From;
   begin
      while I <= S'Last and then S (I) in '0' .. '9' loop
         pragma Loop_Invariant (I in From .. S'Last);
         pragma Loop_Invariant
           (for all K in From .. I - 1 => S (K) in '0' .. '9');
         pragma Loop_Variant (Increases => I);
         I := I + 1;
      end loop;
      return I;
   end Skip_Digits;

   function Scan_Number (S : String; Pos : Positive) return Natural is
      I : Positive := Pos;
   begin
      if S (I) = '-' then
         if I = S'Last then
            return 0;
         end if;
         I := I + 1;
      end if;

      --  Integer part: a lone 0, or a non-zero digit and more digits.
      if S (I) = '0' then
         I := I + 1;
      elsif S (I) in '1' .. '9' then
         I := Skip_Digits (S, I + 1);
      else
         return 0;
      end if;

      --  Fraction: a '.' only counts when digits follow it.
      if I <= S'Last and then S (I) = '.' then
         declare
            After : constant Positive := Skip_Digits (S, I + 1);
         begin
            if After > I + 1 then
               I := After;
            end if;
         end;
      end if;

      --  Exponent: e or E, an optional sign, and at least one digit.
      if I <= S'Last and then S (I) in 'e' | 'E' then
         declare
            Digits_From : Positive := I + 1;
         begin
            if Digits_From <= S'Last and then S (Digits_From) in '+' | '-' then
               Digits_From := Digits_From + 1;
            end if;
            declare
               After : constant Positive := Skip_Digits (S, Digits_From);
            begin
               if After > Digits_From then
                  I := After;
               end if;
            end;
         end;
      end if;

      return I - 1;
   end Scan_Number;

   function Hex_Value (C : Character) return Integer
   is (case C is
         when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
         when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
         when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
         when others     => -1);

   function Combine_Surrogates (High, Low : Natural) return Natural
   is (16#1_0000# + (High - 16#D800#) * 16#400# + (Low - 16#DC00#));

   function Escaped_Length (S : String) return Natural is
      Total : Natural := 0;
   begin
      for I in S'Range loop
         pragma Loop_Invariant (Total >= I - S'First);
         pragma Loop_Invariant (Total <= 6 * (I - S'First));
         Total := Total + Escape_Width (S (I));
      end loop;
      return Total;
   end Escaped_Length;

end Synapse.Core.JSON_Lexical;
