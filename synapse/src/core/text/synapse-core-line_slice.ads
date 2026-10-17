with Synapse.Core.Options;
--  Lines of a text by number, the way `sed -n 'a,bp'` counts them: a line
--  keeps its terminating line feed, and a final line without one is a line
--  with none.

package Synapse.Core.Line_Slice is

   LF : constant Character := Character'Val (10);

   --  The position of the first line feed at or after From, or 0.
   function Next_Line_Feed (Text : String; From : Integer) return Natural with
     Post =>
      Next_Line_Feed'Result = 0
      or else
      (Next_Line_Feed'Result in Text'Range
       and then Next_Line_Feed'Result >= From);

   --  The number of line feeds, not the number of lines a reader would count:
   --  a file whose last line has no terminator reports one fewer than it
   --  shows. Range checks count the same way, so the two agree.
   function Count_Lines (Text : String) return Natural;

   type Slice_Bounds is record
      From, To : Integer;  --  To = From - 1 for an empty slice
   end record;

   package Bounds_Options is new Synapse.Core.Options (Slice_Bounds);

   subtype Maybe_Bounds is Bounds_Options.Option;

   --  The bytes of lines First .. Last (1-based, inclusive) as positions in
   --  Text. Not found when First is 0, Last is before First, or Last is past
   --  the end of the text: never a short slice, which would hash wrong for an
   --  unrelated reason.
   function Bounds (Text : String; First, Last : Natural) return Maybe_Bounds;

end Synapse.Core.Line_Slice;
