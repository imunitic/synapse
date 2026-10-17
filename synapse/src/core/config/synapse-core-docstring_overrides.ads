with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;

--  Two files a person can write beside a grammar to say what its tree calls a
--  comment and which of its nodes are declarations, for pairing a comment with
--  the declaration under it. Neither is a query that is run: each names node
--  types in the smallest query shape, `(type_name)` with an optional trailing
--  `@capture`, and only the type name is read. Reading the files is the
--  caller's.

package Synapse.Core.Docstring_Overrides is

   --  The node type of a comment when nothing says otherwise.
   Default_Comment_Type : constant String := "comment";

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   --  The bytes between the first `(` and the next `)`, `@` or whitespace.
   --  None when there is no `(`, or nothing between it and what ends it.
   function Single_Node_Type (Source : String) return Maybe_Text;

   --  The comment node type a `<ext>.comments.scm` names, or the default when
   --  it names none.
   function Comment_Type (Source : String) return String;

   --  The node types a `<ext>.declarations.scm` accepts as a declaration
   --  although they have no `name` field: one `(type_name)` per line, and a
   --  line with none is skipped. Declarations are otherwise the nodes that
   --  have a `name` field, which no statement does.
   function Declaration_Kinds (Source : String) return Text_Lists.Vector;

end Synapse.Core.Docstring_Overrides;
