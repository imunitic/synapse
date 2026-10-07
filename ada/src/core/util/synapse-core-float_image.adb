with Ada.Float_Text_IO;
with Ada.Strings.Fixed;

package body Synapse.Core.Float_Image is

   --  Digits and the power of ten of the first digit, from the `d.ddE+xx`
   --  shape Float_Text_IO writes.
   procedure Split
     (Text     :     String; Digits_Out : out String; Count : out Natural;
      Exponent : out Integer)
   is
      E : constant Natural := Ada.Strings.Fixed.Index (Text, "E");
   begin
      Count := 0;
      for I in Text'First .. E - 1 loop
         if Text (I) in '0' .. '9' then
            Count                                     := Count + 1;
            Digits_Out (Digits_Out'First + Count - 1) := Text (I);
         end if;
      end loop;
      Exponent := Integer'Value (Text (E + 1 .. Text'Last));
   end Split;

   function Shortest (F : Float) return String is
      Magnitude : constant Float  := abs F;
      Sign      : constant String := (if F < 0.0 then "-" else "");
   begin
      if Magnitude = 0.0 then
         return "0";
      end if;
      for Precision in 2 .. 9 loop
         declare
            Buffer   : String (1 .. 40);
            Digit_At : String (1 .. 16);
            Count    : Natural;
            Exponent : Integer;
         begin
            Ada.Float_Text_IO.Put
              (Buffer, Magnitude, Aft => Precision - 1, Exp => 3);
            if Precision = 9 or else Float'Value (Buffer) = Magnitude then
               Split
                 (Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both), Digit_At,
                  Count, Exponent);
               while Count > 1 and then Digit_At (Count) = '0' loop
                  Count := Count - 1;
               end loop;
               declare
                  Ds : constant String := Digit_At (1 .. Count);
               begin
                  if Exponent >= 0 then
                     if Count <= Exponent + 1 then
                        return Sign & Ds & [1 .. Exponent + 1 - Count => '0'];
                     end if;
                     return
                       Sign & Ds (1 .. Exponent + 1) & "." &
                       Ds (Exponent + 2 .. Count);
                  end if;
                  return Sign & "0." & [1 .. -Exponent - 1 => '0'] & Ds;
               end;
            end if;
         end;
      end loop;
      return Sign & "0";
   end Shortest;

end Synapse.Core.Float_Image;
