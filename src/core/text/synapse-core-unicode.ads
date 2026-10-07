with Synapse.Core.Options;
--  NFC normalization and simple case folding over UTF-8 `String`s.
--
--  Scope is canonical composition (NFC) and simple case folding for equality
--  and search. Invalid UTF-8 is never an error: comparisons report unequal or
--  not found, and the transforming functions (in the child package
--  Transforms) return their input unchanged.

with Synapse.Core.UTF8;
with Synapse.Core.Unicode_Tables;

package Synapse.Core.Unicode with
  SPARK_Mode
is

   subtype Code_Point is UTF8.Code_Point;

   --  Longest text the allocating transforms accept, in bytes.
   Max_Text_Length : constant := 2**28;

   function Fits (S : String) return Boolean is
     (S'Last < Positive'Last and then S'Length <= Max_Text_Length);

   ---------------------------------------------------------------------------
   --  Per-code-point data
   ---------------------------------------------------------------------------

   --  Canonical combining class; 0 for a starter.
   function Combining_Class (CP : Code_Point) return Natural with
     Post => Combining_Class'Result <= 254;

   --  Simple case folding of one code point (itself when it has no folding).
   function Simple_Fold (CP : Code_Point) return Code_Point;

   package Composition_Options is new Synapse.Core.Options (Code_Point);

   subtype Composition is Composition_Options.Option;

   --  The primary composite of the pair A, B, if any. Hangul jamo compose
   --  algorithmically.
   function Compose_Pair (A, B : Code_Point) return Composition;

   subtype Decomposition_Length is
     Positive range 1 .. Unicode_Tables.Max_Decomposition;

   type Code_Point_Array is array (Positive range <>) of Code_Point;

   type Decomposition is record
      Length : Decomposition_Length                                     := 1;
      Items  : Code_Point_Array (1 .. Unicode_Tables.Max_Decomposition) :=
        [others => 0];
   end record;

   --  The full canonical decomposition of CP (CP itself when it has none).
   --  Hangul syllables decompose algorithmically.
   function Decompose (CP : Code_Point) return Decomposition;

   ---------------------------------------------------------------------------
   --  Comparison
   ---------------------------------------------------------------------------

   --  Equality after simple case folding. No normalization is applied.
   function Eq_Case_Fold (A, B : String) return Boolean with
     Pre => A'Last < Positive'Last and then B'Last < Positive'Last;

     ---------------------------------------------------------------------------
     --  Search
     ---------------------------------------------------------------------------

     --  A range of bytes of a text, both ends included.
   type Byte_Range is record
      First, Last : Positive;
   end record;

   package Match_Options is new Synapse.Core.Options (Byte_Range);

   subtype Match is Match_Options.Option;

   --  The first case-fold match of Needle in Haystack, as a byte range of
   --  Haystack. The range's length can differ from Needle's. An empty Needle
   --  finds nothing.
   function Find_Case_Fold (Haystack, Needle : String) return Match with
     Pre => Haystack'Last < Positive'Last and then Needle'Last < Positive'Last,
     Post =>
      (if Find_Case_Fold'Result.Found then
         Find_Case_Fold'Result.Value.First in Haystack'Range
         and then Find_Case_Fold'Result.Value.Last in Haystack'Range
         and then Find_Case_Fold'Result.Value.First <=
           Find_Case_Fold'Result.Value.Last);

   function Contains_Case_Fold (Haystack, Needle : String) return Boolean with
     Pre => Haystack'Last < Positive'Last and then Needle'Last < Positive'Last;

   --  Non-overlapping occurrences. An empty Needle counts zero.
   function Count_Case_Fold (Haystack, Needle : String) return Natural with
     Pre => Haystack'Last < Positive'Last and then Needle'Last < Positive'Last;

end Synapse.Core.Unicode;
