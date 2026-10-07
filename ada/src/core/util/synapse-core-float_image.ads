--  Text for a single-precision number.
package Synapse.Core.Float_Image is

   --  The fewest decimal digits that read back as exactly F, written without
   --  an exponent: `3`, `2.5`, `0.33333334`, `0.00001`. A whole number has no
   --  fraction part. This is the form a search score is printed in.
   function Shortest (F : Float) return String;

end Synapse.Core.Float_Image;
