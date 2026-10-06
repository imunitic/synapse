package body Synapse.Core.UTF8 with SPARK_Mode is

   function Sequence_Length (S : String; Pos : Positive) return Natural is
   begin
      if Is_1_Byte (S, Pos) then
         return 1;
      elsif Is_2_Byte (S, Pos) then
         return 2;
      elsif Is_3_Byte (S, Pos) then
         return 3;
      elsif Is_4_Byte (S, Pos) then
         return 4;
      else
         return 0;
      end if;
   end Sequence_Length;

   function Scalar_At (S : String; Pos : Positive) return Scalar_Value is
      Length : constant Natural := Sequence_Length (S, Pos);
      B0     : constant Natural := Byte (S, Pos);
   begin
      case Length is
         when 1 =>
            return B0;

         when 2 =>
            return (B0 - 16#C0#) * 64 + (Byte (S, Pos + 1) - 16#80#);

         when 3 =>
            return
              (B0 - 16#E0#) * 4096
              + (Byte (S, Pos + 1) - 16#80#) * 64
              + (Byte (S, Pos + 2) - 16#80#);

         when others =>
            return
              (B0 - 16#F0#) * 262_144
              + (Byte (S, Pos + 1) - 16#80#) * 4096
              + (Byte (S, Pos + 2) - 16#80#) * 64
              + (Byte (S, Pos + 3) - 16#80#);
      end case;
   end Scalar_At;

   procedure Decode
     (S : String; Pos : in out Positive; CP : out Scalar_Value) is
   begin
      CP := Scalar_At (S, Pos);
      Pos := Pos + Sequence_Length (S, Pos);
   end Decode;

   function Is_Valid (S : String) return Boolean is
   begin
      if S'Length = 0 then
         return True;
      end if;

      declare
         Pos : Positive := S'First;
      begin
         while Pos <= S'Last loop
            pragma Loop_Invariant (Pos >= S'First);
            pragma Loop_Variant (Increases => Pos);
            declare
               Length : constant Natural := Sequence_Length (S, Pos);
            begin
               if Length = 0 then
                  return False;
               end if;
               Pos := Pos + Length;
            end;
         end loop;
      end;
      return True;
   end Is_Valid;

   function Encoded_Length (CP : Scalar_Value) return Positive
   is (if CP < 16#80# then 1
       elsif CP < 16#800# then 2
       elsif CP < 16#1_0000# then 3
       else 4);

   function Encode (CP : Scalar_Value) return String is

      function Cont (Bits : Natural) return Character
      is (Character'Val (16#80# + Bits mod 64));

   begin
      case Encoded_Length (CP) is
         when 1 =>
            return [Character'Val (CP)];

         when 2 =>
            return [Character'Val (16#C0# + CP / 64), Cont (CP)];

         when 3 =>
            return
              [Character'Val (16#E0# + CP / 4096),
               Cont (CP / 64),
               Cont (CP)];

         when others =>
            return
              [Character'Val (16#F0# + CP / 262_144),
               Cont (CP / 4096),
               Cont (CP / 64),
               Cont (CP)];
      end case;
   end Encode;

end Synapse.Core.UTF8;
