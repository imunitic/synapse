--  Strict UTF-8 over `String`: every Character holds one byte. Strings are
--  addressed by their own 'Range; the first index need not be 1.

package Synapse.Core.UTF8 with SPARK_Mode is

   subtype Code_Point is Natural range 0 .. 16#10_FFFF#;

   subtype Scalar_Value is Code_Point
   with Dynamic_Predicate => Scalar_Value not in 16#D800# .. 16#DFFF#;

   --  The byte at index I of S, as a number.
   function Byte (S : String; I : Positive) return Natural
   is (Character'Pos (S (I)))
   with Pre => I in S'Range;

   --  Whether S has a byte Offset places after Pos, and it lies in
   --  Low .. High.
   function Has_Byte
     (S      : String;
      Pos    : Positive;
      Offset : Positive;
      Low    : Natural := 16#80#;
      High   : Natural := 16#BF#) return Boolean
   is (Offset <= S'Last - Pos and then Byte (S, Pos + Offset) in Low .. High)
   with Pre => S'Last < Positive'Last and then Pos in S'Range;

   --  Well-formed sequences of each length starting at Pos. Overlong forms,
   --  surrogates and values above U+10FFFF are excluded by the byte ranges.

   function Is_1_Byte (S : String; Pos : Positive) return Boolean
   is (Byte (S, Pos) < 16#80#)
   with Pre => Pos in S'Range;

   function Is_2_Byte (S : String; Pos : Positive) return Boolean
   is (Byte (S, Pos) in 16#C2# .. 16#DF# and then Has_Byte (S, Pos, 1))
   with Pre => S'Last < Positive'Last and then Pos in S'Range;

   function Is_3_Byte (S : String; Pos : Positive) return Boolean
   is ((Byte (S, Pos) = 16#E0#
        and then Has_Byte (S, Pos, 1, Low => 16#A0#)
        and then Has_Byte (S, Pos, 2))
       or else
         (Byte (S, Pos) = 16#ED#
          and then Has_Byte (S, Pos, 1, High => 16#9F#)
          and then Has_Byte (S, Pos, 2))
       or else
         (Byte (S, Pos) in 16#E1# .. 16#EC# | 16#EE# .. 16#EF#
          and then Has_Byte (S, Pos, 1)
          and then Has_Byte (S, Pos, 2)))
   with Pre => S'Last < Positive'Last and then Pos in S'Range;

   function Is_4_Byte (S : String; Pos : Positive) return Boolean
   is ((Byte (S, Pos) = 16#F0#
        and then Has_Byte (S, Pos, 1, Low => 16#90#)
        and then Has_Byte (S, Pos, 2)
        and then Has_Byte (S, Pos, 3))
       or else
         (Byte (S, Pos) = 16#F4#
          and then Has_Byte (S, Pos, 1, High => 16#8F#)
          and then Has_Byte (S, Pos, 2)
          and then Has_Byte (S, Pos, 3))
       or else
         (Byte (S, Pos) in 16#F1# .. 16#F3#
          and then Has_Byte (S, Pos, 1)
          and then Has_Byte (S, Pos, 2)
          and then Has_Byte (S, Pos, 3)))
   with Pre => S'Last < Positive'Last and then Pos in S'Range;

   --  Length in bytes of the well-formed sequence starting at Pos, or 0 when
   --  the bytes there are not well-formed UTF-8.
   function Sequence_Length (S : String; Pos : Positive) return Natural
   with
     Pre  => S'Last < Positive'Last and then Pos in S'Range,
     Post =>
       Sequence_Length'Result <= 4
       and then (Sequence_Length'Result = 1) = Is_1_Byte (S, Pos)
       and then (Sequence_Length'Result = 2) = Is_2_Byte (S, Pos)
       and then (Sequence_Length'Result = 3) = Is_3_Byte (S, Pos)
       and then (Sequence_Length'Result = 4) = Is_4_Byte (S, Pos)
       and then (Sequence_Length'Result = 0
                 or else Sequence_Length'Result - 1 <= S'Last - Pos);

   --  The scalar value of the well-formed sequence starting at Pos.
   function Scalar_At (S : String; Pos : Positive) return Scalar_Value
   with
     Pre =>
       S'Last < Positive'Last
       and then Pos in S'Range
       and then Sequence_Length (S, Pos) > 0,
     Post =>
       (case Sequence_Length (S, Pos) is
          when 1 => Scalar_At'Result = Byte (S, Pos),
          when 2 =>
            Scalar_At'Result
            = (Byte (S, Pos) - 16#C0#) * 64 + (Byte (S, Pos + 1) - 16#80#),
          when 3 =>
            Scalar_At'Result
            = (Byte (S, Pos) - 16#E0#) * 4096
              + (Byte (S, Pos + 1) - 16#80#) * 64
              + (Byte (S, Pos + 2) - 16#80#),
          when 4 =>
            Scalar_At'Result
            = (Byte (S, Pos) - 16#F0#) * 262_144
              + (Byte (S, Pos + 1) - 16#80#) * 4096
              + (Byte (S, Pos + 2) - 16#80#) * 64
              + (Byte (S, Pos + 3) - 16#80#),
          when others => True);

   --  Reads the scalar value at Pos and advances Pos past its sequence.
   procedure Decode
     (S : String; Pos : in out Positive; CP : out Scalar_Value)
   with
     Pre  =>
       S'Last < Positive'Last
       and then Pos in S'Range
       and then Sequence_Length (S, Pos) > 0,
     Post =>
       CP = Scalar_At (S, Pos'Old)
       and then Pos = Pos'Old + Sequence_Length (S, Pos'Old);

   --  Whether all of S is well-formed UTF-8.
   function Is_Valid (S : String) return Boolean
   with Pre => S'Last < Positive'Last;

   --  Atom value of a byte that is not part of a well-formed sequence: this
   --  base plus the byte.
   Invalid_Byte_Base : constant := 16#11_0000#;

   --  Reads the atom at Pos: the scalar value of a well-formed sequence, or
   --  Invalid_Byte_Base + byte for a malformed byte, which is an atom of its
   --  own. Width is the number of bytes the atom takes.
   procedure Decode_Lenient
     (S : String; Pos : Positive; Value : out Natural; Width : out Positive)
   with
     Pre  => S'Last < Positive'Last and then Pos in S'Range,
     Post =>
       Width - 1 <= S'Last - Pos and then Value <= Invalid_Byte_Base + 255;

   --  The start of the atom that ends just before Pos, under the segmentation
   --  Decode_Lenient produces reading forward from Floor, and never before
   --  Floor.
   function Previous_Start (S : String; Floor, Pos : Positive) return Positive
   with
     Pre  =>
       S'Last < Positive'Last
       and then Floor >= S'First
       and then Pos > Floor
       and then Pos <= S'Last + 1,
     Post => Previous_Start'Result in Floor .. Pos - 1;

   function Encoded_Length (CP : Scalar_Value) return Positive
   with Post => Encoded_Length'Result <= 4;

   function Encode (CP : Scalar_Value) return String
   with
     Post =>
       Encode'Result'First = 1
       and then Encode'Result'Length = Encoded_Length (CP)
       and then Sequence_Length (Encode'Result, 1) = Encoded_Length (CP)
       and then Scalar_At (Encode'Result, 1) = CP;

end Synapse.Core.UTF8;
