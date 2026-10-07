with Synapse.Core.Options;
with Synapse.Core.Graph_Model;

--  The tag-line codec: tree-sitter's batch output in, a tag out, and the
--  `_refs.tsv` row back out. The index is binary-searched on raw bytes, so a
--  row that differs by one byte is unfindable.
--
--  The line tree-sitter emits is tab-separated:
--
--    Token     <TAB> | class   <TAB>def (15, 13) - (15, 18) `class Token {`
--
--  Field 1 is the name, padded with spaces. Field 2 is the kind behind a ` | `
--  prefix. Field 3 opens with the role, carries a (row, column) - (row,
--  column) span, and ends with the source line between backticks.

package Synapse.Core.Tag_Line is

   package Maybe_Tag_Options is new Synapse.Core.Options (Graph_Model.Tag);

   subtype Maybe_Tag is Maybe_Tag_Options.Option;

   --  One line of batch output as a tag. None for what is not one, which is
   --  not an error: batch output has lines that are not tags. A line has too
   --  few fields, a role other than `def` or `ref`, no `(row,` or a row that
   --  is not a number, or an empty name.
   --
   --  Only the first three tab-separated fields count, so a source line with
   --  a tab in it is cut there and loses its closing backtick. The
   --  expression is what lies between the first backtick and the last; with
   --  a single backtick it is everything after it, and with none it is
   --  empty. Name and kind are trimmed of the padding.
   function Parse (Line : String) return Maybe_Tag with
     Pre => Line'Last < Positive'Last;

   --  One `_refs.tsv` row, ending in a line feed: name, role, kind,
   --  `path:line` and the expression, separated by single tabs. The column
   --  order is a contract with the binary search over the sorted file.
   function Refs_Row (Path : String; Of_Tag : Graph_Model.Tag) return String;

end Synapse.Core.Tag_Line;
