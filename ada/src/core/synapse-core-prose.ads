--  Checks on the shape of Markdown prose: whether paragraphs are wrapped by
--  hand and whether a body holds a stray frontmatter block.
--
--  Text is split at line feeds; a carriage return at the end of a line is not
--  part of it. Fenced code (a line of three backticks or tildes opens it and
--  the next such line closes it) is never prose.

package Synapse.Core.Prose is

   --  Whether a line never counts toward a paragraph: it is blank, indented,
   --  a heading, a blockquote, a table row, a list item (`- `, `* `, `+ `,
   --  or digits followed by `.` or `)` and a space) or a fence line.
   function Is_Excluded_Line (Line : String) return Boolean;

   --  False when some paragraph of Text spans two or more consecutive lines.
   function No_Hard_Wrap (Text : String) return Boolean;

   --  True when every paragraph of Text is broken exactly where a greedy word
   --  wrap at Max_Chars would break it: a word goes on the current line when
   --  the line ends at least as near the width with it as without it, and a
   --  tie starts the next line. The decision about the first word that
   --  overshoots is final for its line. A word longer than the width stands
   --  alone on its line.
   function Hard_Wrap (Text : String; Max_Chars : Positive) return Boolean;

   --  False when, outside fenced code, a `---` line is followed by at least
   --  one `key: value` line with a non-empty value and then another `---`
   --  line. A lone `---` and a block of lines without a value are fine.
   function No_Stray_Frontmatter (Text : String) return Boolean;

end Synapse.Core.Prose;
