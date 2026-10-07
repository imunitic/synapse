--  Pure lexical helpers for the JSON parser and writer. Every function here
--  is proved free of runtime errors.

package Synapse.Core.JSON_Lexical with SPARK_Mode is

   --  The index of the first non-digit at or after From; S'Last + 1 when the
   --  rest of S is all digits.
   function Skip_Digits (S : String; From : Positive) return Positive
   with
     Pre  => S'Last < Positive'Last and then From in S'First .. S'Last + 1,
     Post =>
       Skip_Digits'Result in From .. S'Last + 1
       and then (for all I in From .. Skip_Digits'Result - 1
                 => S (I) in '0' .. '9')
       and then (Skip_Digits'Result = S'Last + 1
                 or else S (Skip_Digits'Result) not in '0' .. '9');

   --  The index of the last character of the RFC 8259 number starting at Pos:
   --  `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, taking as much
   --  as the grammar allows. 0 when no number starts there.
   function Scan_Number (S : String; Pos : Positive) return Natural
   with
     Pre  => S'Last < Positive'Last and then Pos in S'Range,
     Post =>
       Scan_Number'Result = 0 or else Scan_Number'Result in Pos .. S'Last;

   --  Whether a number's text has a fraction or an exponent, so it is not an
   --  integer.
   function Has_Fraction_Or_Exponent (S : String) return Boolean
   is (for some C of S => C in '.' | 'e' | 'E');

   --  The value of a hexadecimal digit, or -1.
   function Hex_Value (C : Character) return Integer
   with Post => Hex_Value'Result in -1 .. 15;

   --  The scalar value a UTF-16 surrogate pair stands for.
   function Combine_Surrogates (High, Low : Natural) return Natural
   with
     Pre  =>
       High in 16#D800# .. 16#DBFF# and then Low in 16#DC00# .. 16#DFFF#,
     Post =>
       Combine_Surrogates'Result
       = 16#1_0000# + (High - 16#D800#) * 16#400# + (Low - 16#DC00#)
       and then Combine_Surrogates'Result in 16#1_0000# .. 16#10_FFFF#;

   --  Bytes C takes inside a JSON string once escaped: 2 for `"`, `\` and the
   --  short escapes (\b \f \n \r \t), 6 for any other control character
   --  (\u00XX), 1 otherwise.
   function Escape_Width (C : Character) return Positive
   is (if C in '"' | '\'
         or else Character'Pos (C) in 8 | 9 | 10 | 12 | 13
       then 2
       elsif Character'Pos (C) < 32
       then 6
       else 1)
   with Post => Escape_Width'Result in 1 | 2 | 6;

   Max_Escapable_Length : constant := Integer'Last / 6;

   --  The length of S once escaped, without the surrounding quotes.
   function Escaped_Length (S : String) return Natural
   with
     Pre  => S'Length <= Max_Escapable_Length,
     Post =>
       Escaped_Length'Result >= S'Length
       and then Escaped_Length'Result <= 6 * S'Length;

end Synapse.Core.JSON_Lexical;
