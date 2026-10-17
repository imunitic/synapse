with Interfaces;

--  Integers as bytes, least significant first: the byte order of every field
--  of the binary caches. Each field is read and written one byte at a time, so
--  the layout is a function of this and not of a compiler's idea of a record,
--  and nothing is assumed about the alignment of the bytes it is read from.

package Synapse.Core.Little_Endian is

   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   --  The integer at the position, which needs 2, 4 or 8 bytes from there.
   function Get_U16 (S : String; Where : Integer) return U16 with
     Pre => Where >= S'First and then Where <= S'Last - 1;

   function Get_U32 (S : String; Where : Integer) return U32 with
     Pre => Where >= S'First and then Where <= S'Last - 3;

   function Get_U64 (S : String; Where : Integer) return U64 with
     Pre => Where >= S'First and then Where <= S'Last - 7;

   function Put_U16 (V : U16) return String with
     Post => Put_U16'Result'Length = 2;

   function Put_U32 (V : U32) return String with
     Post => Put_U32'Result'Length = 4;

   function Put_U64 (V : U64) return String with
     Post => Put_U64'Result'Length = 8;

end Synapse.Core.Little_Endian;
