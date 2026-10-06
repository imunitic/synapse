package body Synapse.Core.Graph_Model is

   function Parse (Text : String) return Maybe_Role is
   begin
      if Text = "def" then
         return (Found => True, Value => Def);
      elsif Text = "ref" then
         return (Found => True, Value => Ref);
      end if;
      return (Found => False);
   end Parse;

   --  The value of a hex digit, or 16 for a character that is not one.
   function Digit (C : Character) return Natural
   is (case C is
         when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
         when others => 16);

   function Hash_From_Hex (Hex : String) return Hash_Result is
      Result : Hash := [others => 0];
   begin
      if Hex'Length /= 40 then
         return (Valid => False);
      end if;
      for I in Result'Range loop
         declare
            High : constant Natural := Digit (Hex (Hex'First + 2 * (I - 1)));
            Low  : constant Natural :=
              Digit (Hex (Hex'First + 2 * (I - 1) + 1));
         begin
            if High = 16 or else Low = 16 then
               return (Valid => False);
            end if;
            Result (I) := High * 16 + Low;
         end;
      end loop;
      return (Valid => True, Value => Result);
   end Hash_From_Hex;

   function Hash_To_Hex (Value : Hash) return String is
      Digits_Of : constant String := "0123456789abcdef";
      Result    : String (1 .. 40);
   begin
      for I in Value'Range loop
         Result (2 * I - 1) := Digits_Of (Value (I) / 16 + 1);
         Result (2 * I) := Digits_Of (Value (I) mod 16 + 1);
      end loop;
      return Result;
   end Hash_To_Hex;

end Synapse.Core.Graph_Model;
