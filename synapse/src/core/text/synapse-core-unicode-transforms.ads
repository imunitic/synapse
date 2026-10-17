--  The transforms that build new text. Their buffers are sized from the
--  input on the heap, which is outside the SPARK subset, so the contracts here
--  are checked at runtime rather than proved.

package Synapse.Core.Unicode.Transforms with SPARK_Mode => Off is

   function Normalize_NFC (S : String) return String
   with
     Pre  => Fits (S),
     Post =>
       (if UTF8.Is_Valid (S)
        then UTF8.Is_Valid (Normalize_NFC'Result)
        else Normalize_NFC'Result = S);

   --  S with every code point replaced by its simple case folding.
   function Fold (S : String) return String
   with
     Pre  => Fits (S),
     Post =>
       (if UTF8.Is_Valid (S)
        then UTF8.Is_Valid (Fold'Result)
        else Fold'Result = S);

   --  NFC then Fold: a canonical key for comparing text.
   function Normalize_Key (S : String) return String
   with Pre => Fits (S);

end Synapse.Core.Unicode.Transforms;
