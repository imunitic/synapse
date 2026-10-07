with Interfaces; use Interfaces;

package body Synapse.Core.Little_Endian is

   function Byte (S : String; At_Index : Integer) return U64 is
     (U64 (Character'Pos (S (At_Index))));

   function Get_U16 (S : String; Where : Integer) return U16 is
     (U16 (Byte (S, Where) or Shift_Left (Byte (S, Where + 1), 8)));

   function Get_U32 (S : String; Where : Integer) return U32 is
      Value : U64 := 0;
   begin
      for I in 0 .. 3 loop
         Value := Value or Shift_Left (Byte (S, Where + I), 8 * I);
      end loop;
      return U32 (Value);
   end Get_U32;

   function Get_U64 (S : String; Where : Integer) return U64 is
      Value : U64 := 0;
   begin
      for I in 0 .. 7 loop
         Value := Value or Shift_Left (Byte (S, Where + I), 8 * I);
      end loop;
      return Value;
   end Get_U64;

   function Put (V : U64; Count : Positive) return String is
      Result : String (1 .. Count);
      Rest   : U64 := V;
   begin
      for I in Result'Range loop
         Result (I) := Character'Val (Rest and 16#FF#);
         Rest       := Shift_Right (Rest, 8);
      end loop;
      return Result;
   end Put;

   function Put_U16 (V : U16) return String is (Put (U64 (V), 2));

   function Put_U32 (V : U32) return String is (Put (U64 (V), 4));

   function Put_U64 (V : U64) return String is (Put (V, 8));

end Synapse.Core.Little_Endian;
