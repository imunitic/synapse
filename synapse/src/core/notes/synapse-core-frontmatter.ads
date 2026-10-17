with Synapse.Core.Options;
--  A note's YAML frontmatter, read and rewritten as text.
--
--  The frontmatter is the block at the top of a note between two lines that
--  are exactly `---`. Nothing here parses YAML: a line is the unit, and a
--  key is whatever starts a line at column zero and ends at a colon. Reading
--  finds fields; writing replaces one line, or inserts one just before the
--  closing fence, and leaves every other byte of the note as it was.
--
--  A block must be closed: an opening fence with no closing one is not
--  frontmatter. Lines may end in LF or CR LF; the CR is never part of a line's
--  text, and a write keeps the line endings it finds.

package Synapse.Core.Frontmatter with
  SPARK_Mode
is

   --  Longest note, key and rendered value the writers accept, in bytes.
   Max_Note_Length  : constant := 2**28;
   Max_Key_Length   : constant := 2**10;
   Max_Value_Length : constant := 2**20;

   --  A range of bytes in a text: [First, Stop), counted from 0 at the text's
   --  first byte.
   type Span is record
      First : Natural;
      Stop  : Natural;
   end record;

   package Span_Options is new Synapse.Core.Options (Span);

   subtype Maybe_Span is Span_Options.Option;

   ---------------------------------------------------------------------------
   --  Locating the block
   ---------------------------------------------------------------------------

   type Block (Present : Boolean := False) is record
      case Present is
         when True =>
            Lines_Start : Natural;  --  the first line after the opening fence
            Close       : Natural;  --  where the closing fence's line begins
            Body_Start  : Natural;  --  just after the closing fence's line

         when False =>
            null;
      end case;
   end record;

   function Locate (Text : String) return Block with
     Pre  => Text'Last < Positive'Last,
     Post =>
      (if Locate'Result.Present then
         Locate'Result.Lines_Start <= Locate'Result.Close
         and then Locate'Result.Close < Locate'Result.Body_Start
         and then Locate'Result.Body_Start <= Text'Length);

   function Has_Frontmatter (Text : String) return Boolean is
     (Locate (Text).Present) with
     Pre => Text'Last < Positive'Last;

   --  The next line of the block after Position, without its line ending.
   --  Start Position at Lines_Start; Found is False once the closing fence is
   --  reached.
   procedure Next_Line
     (Text  : String; B : Block; Position : in out Natural; Line : out Span;
      Found : out Boolean) with
     Pre  =>
      Text'Last < Positive'Last and then B.Present
      and then B.Close <= Text'Length and then Position <= B.Close,
     Post =>
      Position >= Position'Old and then Position <= B.Close
      and then
      (if Found then
         Position > Position'Old and then Line.First <= Line.Stop
         and then Line.Stop <= B.Close);

   --  The text after the block, or all of Text when there is no block.
   function Body_After (Text : String) return Span with
     Pre  => Text'Last < Positive'Last,
     Post =>
      Body_After'Result.First <= Body_After'Result.Stop
      and then Body_After'Result.Stop = Text'Length;

   ---------------------------------------------------------------------------
   --  Reading
   ---------------------------------------------------------------------------

   --  Whether Line is `{Key}: ...` at column zero: Key is a whole key, so a
   --  lookup for `title` does not match `subtitle:` or `titled:`.
   function Is_Key_Line (Line, Key : String) return Boolean is
     (Line'Length > Key'Length
      and then Line (Line'First .. Line'First + Key'Length - 1) = Key
      and then Line (Line'First + Key'Length) = ':') with
     Pre => Line'Last < Positive'Last;

   --  The line, as a span, of the first top-level `Key:` in the block.
   function Find_Key_Line (Text, Key : String) return Maybe_Span with
     Pre  => Text'Last < Positive'Last and then Key'Last < Positive'Last,
     Post =>
      (if Find_Key_Line'Result.Found then
         Find_Key_Line'Result.Value.First <= Find_Key_Line'Result.Value.Stop
         and then Find_Key_Line'Result.Value.Stop <= Text'Length
         and then
           Find_Key_Line'Result.Value.Stop - Find_Key_Line'Result.Value.First >
           Key'Length);

   --  The text of a top-level field after its colon: leading blanks skipped,
   --  and at most one `"` removed from each end, so a value that ends in an
   --  escaped quote keeps it. Escapes are not undone.
   function Find_Field (Text, Key : String) return Maybe_Span with
     Pre  => Text'Last < Positive'Last and then Key'Last < Positive'Last,
     Post =>
      (if Find_Field'Result.Found then
         Find_Field'Result.Value.First <= Find_Field'Result.Value.Stop
         and then Find_Field'Result.Value.Stop <= Text'Length);

   --  Splits a column-zero `key: value` line into key and value spans (blanks
   --  trimmed). Not found for a line that starts with a space or tab, has no
   --  colon, or has an empty key.
   procedure Split_Key_Value
     (Line : String; Found : out Boolean; Key, Value : out Span) with
     Pre  => Line'Last < Positive'Last,
     Post =>
      (if Found then
         Key.First <= Key.Stop and then Key.Stop <= Line'Length
         and then Value.First <= Value.Stop
         and then Value.Stop <= Line'Length);

   ---------------------------------------------------------------------------
   --  Quoting
   ---------------------------------------------------------------------------

   --  Whether S must be quoted to read back as the string it is: it is empty,
   --  starts or ends with a space or tab, contains `: ` or ` #` or a line
   --  break (LF or CR), ends
   --  with a colon, starts with one of ``"'#&*!|>%@`[]{},``, is `true`,
   --  `false`, `null` or `~`, or is made only of digits.
   function Needs_Quoting (S : String) return Boolean with
     Pre => S'Last < Positive'Last;

   --  S in double quotes, with `\`, `"`, newline and carriage return escaped.
   function Quoted (S : String) return String with
     Pre  => S'Length <= Max_Value_Length,
     Post =>
      Quoted'Result'First = 1 and then Quoted'Result'Length >= S'Length + 2
      and then Quoted'Result (1) = '"'
      and then Quoted'Result (Quoted'Result'Last) = '"';

   --  S as a YAML scalar: quoted when it needs to be.
   function Render_Scalar (S : String) return String with
     Pre  => S'Last < Positive'Last and then S'Length <= Max_Value_Length,
     Post => Render_Scalar'Result'Length >= S'Length;

   ---------------------------------------------------------------------------
   --  Writing
   ---------------------------------------------------------------------------

   --  Note with the line `Key: Rendered` replacing the key's existing line, or
   --  inserted just before the closing fence when the key is absent. Every
   --  other byte is unchanged, line endings included.
   function Set_Rendered (Note, Key, Rendered : String) return String with
     Pre  =>
      Note'Last < Positive'Last and then Note'Length <= Max_Note_Length
      and then Key'Last < Positive'Last and then Key'Length <= Max_Key_Length
      and then Rendered'Length <= Max_Value_Length
      and then Has_Frontmatter (Note),
     Post => Set_Rendered'Result'First = 1;

end Synapse.Core.Frontmatter;
