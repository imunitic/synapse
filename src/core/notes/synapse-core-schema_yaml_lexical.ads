--  The decisions the schema YAML reader makes about a line or a scalar, as
--  pure functions over text. Offsets are 0-based from the string's first
--  byte. Quotes are tracked the way the reader does everywhere: a quote starts
--  a quoted run that ends at the same quote character, and inside double
--  quotes a backslash escapes the next character.

package Synapse.Core.Schema_YAML_Lexical with SPARK_Mode is

   function Is_Alpha (C : Character) return Boolean
   is (C in 'a' .. 'z' | 'A' .. 'Z');

   function Is_Digit (C : Character) return Boolean
   is (C in '0' .. '9');

   --  A mapping key: an ASCII letter or `_`, then letters, digits, `_` or `-`.
   function Valid_Key (Key : String) return Boolean
   is (Key'Length > 0
       and then (Is_Alpha (Key (Key'First)) or else Key (Key'First) = '_')
       and then
         (for all I in Key'First + 1 .. Key'Last
          => Is_Alpha (Key (I))
             or else Is_Digit (Key (I))
             or else Key (I) in '_' | '-'))
   with Pre => Key'Last < Positive'Last;

   --  A line (indentation already removed) that starts a list item: `-` alone
   --  or followed by a space.
   function Is_List_Line (Text : String) return Boolean
   is (Text'Length > 0
       and then Text (Text'First) = '-'
       and then (Text'Length = 1 or else Text (Text'First + 1) = ' '))
   with Pre => Text'Last < Positive'Last;

   --  Where a comment starts: the first `#` outside quotes that begins the
   --  line or follows whitespace. Line'Length when there is none.
   function Comment_Start (Line : String) return Natural
   with
     Pre  => Line'Last < Positive'Last,
     Post => Comment_Start'Result <= Line'Length;

   type Colon is record
      Found         : Boolean;  --  a key/value colon exists
      Stray_Bracket : Boolean;  --  a `]` with no `[` before it
      Offset        : Natural;  --  of the colon, when Found
   end record;

   --  The first `:` outside quotes and outside square brackets. A closing
   --  bracket with no opening one stops the search with Stray_Bracket.
   function Pair_Colon (Text : String) return Colon
   with
     Pre  => Text'Last < Positive'Last,
     Post =>
       (if Pair_Colon'Result.Found
        then Pair_Colon'Result.Offset < Text'Length
             and then not Pair_Colon'Result.Stray_Bracket);

   --  Spellings of values YAML would read as another type, which the reader
   --  refuses to guess at: Null, NULL, ~, the yes/no and on/off families, and
   --  the .inf and .nan spellings. (Lower-case `null` is a real value.)
   function Is_Ambiguous_Implicit (Text : String) return Boolean
   is (Text in
         "Null" | "NULL" | "~" | "yes" | "Yes" | "YES" | "no" | "No" | "NO"
         | "on" | "On" | "ON" | "off" | "Off" | "OFF" | ".inf" | ".Inf"
         | ".INF" | ".nan" | ".NaN" | ".NAN");

   --  An optional `-` and at least one digit, and nothing else.
   function Looks_Numeric (Text : String) return Boolean
   is (Text'Length > 0
       and then
         (if Text (Text'First) = '-'
          then
            Text'Length > 1
            and then (for all I in Text'First + 1 .. Text'Last
                      => Is_Digit (Text (I)))
          else (for all C of Text => Is_Digit (C))))
   with Pre => Text'Last < Positive'Last;

   --  An `&` or `*` anywhere: an anchor or alias, refused in unquoted text.
   function Has_Anchor_Mark (Text : String) return Boolean
   is (for some C of Text => C in '&' | '*');

end Synapse.Core.Schema_YAML_Lexical;
