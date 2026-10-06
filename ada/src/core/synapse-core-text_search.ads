with Ada.Containers.Vectors;

with Synapse.Core.Text_Lists;

--  Case-insensitive text search over a text of lines. Case is folded with
--  Unicode simple case folding. Lines end at a line feed.

package Synapse.Core.Text_Search is

   --  The first line of Text that contains Query, or none.
   type Maybe_Line (Found : Boolean := False) is record
      case Found is
         when True =>
            First, Last : Positive;  --  its bytes in Text, no line feed

         when False =>
            null;
      end case;
   end record;

   function First_Matching_Line (Text, Query : String) return Maybe_Line
   with Pre => Text'Last < Positive'Last and then Query'Last < Positive'Last;

   --  The first line that contains any of Terms.
   function First_Matching_Line_Any
     (Text : String; Terms : Text_Lists.Vector) return Maybe_Line
   with Pre => Text'Last < Positive'Last;

   --  Non-overlapping occurrences of Needle in Haystack; zero for an empty
   --  Needle.
   function Count_Ignore_Case (Haystack, Needle : String) return Natural
   with
     Pre =>
       Haystack'Last < Positive'Last and then Needle'Last < Positive'Last;

   --  An inclusive range of 1-based line numbers.
   type Line_Range is record
      First, Last : Positive;
   end record;

   package Range_Vectors is new Ada.Containers.Vectors (Positive, Line_Range);

   --  The lines of Text that contain any of Terms, numbered from First_Line,
   --  with consecutive lines merged into one range.
   function Match_Ranges
     (Text       : String;
      First_Line : Positive;
      Terms      : Text_Lists.Vector) return Range_Vectors.Vector
   with Pre => Text'Last < Positive'Last;

   --  `12-14,40-41,88`: comma-separated, a one-line range as its bare number.
   function Image (Ranges : Range_Vectors.Vector) return String;

end Synapse.Core.Text_Search;
