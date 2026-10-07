--  Pure text helpers for reading a note: file names, comments, numbers,
--  timestamps and the lines that make up Markdown headings. Every function
--  here is proved free of runtime errors.

package Synapse.Core.Note_Text with SPARK_Mode is

   --  A range of characters: [First, Stop), counted from 0 at a string's
   --  first character.
   type Span is record
      First : Natural;
      Stop  : Natural;
   end record;

   ---------------------------------------------------------------------------
   --  Paths and comments
   ---------------------------------------------------------------------------

   --  The file name of Path without its directory and without a `.md` suffix.
   --  Both `/` and `\` separate directories.
   function Filename_Stem (Path : String) return Span
   with
     Pre  => Path'Last < Positive'Last,
     Post =>
       Filename_Stem'Result.First <= Filename_Stem'Result.Stop
       and then Filename_Stem'Result.Stop <= Path'Length;

   --  How much of Raw is left once a trailing comment is cut: a `#` that is
   --  outside quotes and either starts Raw or follows whitespace begins the
   --  comment. A quote ends at the same quote character; there are no
   --  escapes.
   function Strip_Trailing_Comment (Raw : String) return Natural
   with
     Pre  => Raw'Last < Positive'Last,
     Post => Strip_Trailing_Comment'Result <= Raw'Length;

   ---------------------------------------------------------------------------
   --  Numbers
   ---------------------------------------------------------------------------

   --  An optional `-` and digits, whose value fits Long_Long_Integer.
   procedure Parse_Decimal
     (Raw : String; Valid : out Boolean; Value : out Long_Long_Integer)
   with Pre => Raw'Last < Positive'Last;

   ---------------------------------------------------------------------------
   --  Timestamps
   ---------------------------------------------------------------------------

   --  RFC 3339: `YYYY-MM-DDTHH:MM:SS` then `Z` or a numeric offset with a
   --  colon (`+02:00`). The shape and the ranges of each field are checked
   --  (month 1 to 12, day 1 to 31, hour 0 to 23, minute and second 0 to 59,
   --  offset hour 0 to 23, offset minute 0 to 59), not the calendar.
   function Valid_Timestamp (Value : String) return Boolean
   with Pre => Value'Last < Positive'Last;

   --  Days since 1970-01-01 of a calendar date (proleptic Gregorian).
   function Days_From_Civil
     (Year : Integer; Month, Day : Positive) return Long_Long_Integer
   with
     Pre  => Year in 0 .. 9999 and then Month <= 12 and then Day <= 31,
     Post => Days_From_Civil'Result in -719_528 .. 2_932_897;

   --  Seconds since 1970-01-01T00:00:00Z of a valid timestamp, taking its
   --  offset into account, so equal instants written with different offsets
   --  give equal results.
   procedure Parse_Instant_Seconds
     (Value : String; Valid : out Boolean; Seconds : out Long_Long_Integer)
   with Pre => Value'Last < Positive'Last;

   ---------------------------------------------------------------------------
   --  Markdown lines
   ---------------------------------------------------------------------------

   --  A line that opens or closes fenced code: three backticks or three
   --  tildes after optional spaces or tabs.
   function Is_Fence_Line (Line : String) return Boolean
   with Pre => Line'Last < Positive'Last;

   --  The level, 1 to 6, of a heading line: one to six `#` at column zero and
   --  then a space. 0 when Line is not a heading.
   function Heading_Level (Line : String) return Natural
   with
     Pre  => Line'Last < Positive'Last,
     Post =>
       Heading_Level'Result <= 6
       and then (Heading_Level'Result = 0
                 or else Heading_Level'Result < Line'Length);

   --  The title of a heading line of the given level: what follows the `#`
   --  run and its space, without leading or trailing spaces and tabs.
   function Heading_Title (Line : String; Level : Positive) return Span
   with
     Pre  =>
       Line'Last < Positive'Last
       and then Level <= 6
       and then Heading_Level (Line) = Level,
     Post =>
       Heading_Title'Result.First <= Heading_Title'Result.Stop
       and then Heading_Title'Result.Stop <= Line'Length;

end Synapse.Core.Note_Text;
