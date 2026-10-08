package body Synapse.Test_Bytes is

   Digits_Of : constant String := "0123456789abcdef";

   function Value (C : Character) return Natural is
     (case C is when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
        when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
        when others => raise Constraint_Error with "not a hex digit");

   function From_Hex (Hex : String) return String is
      Result : String (1 .. Hex'Length / 2);
   begin
      for I in Result'Range loop
         Result (I) :=
           Character'Val
             (Value (Hex (Hex'First + 2 * (I - 1))) * 16 +
              Value (Hex (Hex'First + 2 * (I - 1) + 1)));
      end loop;
      return Result;
   end From_Hex;

   function To_Hex (Bytes : String) return String is
      Result : String (1 .. 2 * Bytes'Length);
   begin
      for I in Bytes'Range loop
         declare
            V : constant Natural := Character'Pos (Bytes (I));
            K : constant Natural := 2 * (I - Bytes'First);
         begin
            Result (K + 1) := Digits_Of (V / 16 + 1);
            Result (K + 2) := Digits_Of (V mod 16 + 1);
         end;
      end loop;
      return Result;
   end To_Hex;

end Synapse.Test_Bytes;
