with Synapse.Core.Grammar_Registry;
with Synapse.Core.Results;
with Synapse.Core.Text_Lists;
with Synapse.Ports.Docstring_Pairs;

--  Structural pairing of a comment with the declaration under it, apart from
--  the tagger even though both walk the same parse. Checking docstrings is a
--  feature of its own and must not share fate with tag extraction: a grammar
--  with no usable `tags.scm` would otherwise lose it for a reason that has
--  nothing to do with docstrings.
--
--  Pairing starts from a comment node and walks forward over directly
--  adjacent (row consecutive) sibling comments, collecting a run, the way a
--  doc comment is written. The run ends at a blank line, which makes it a
--  floating comment and not a docstring, or at the node after it. That node
--  has to be a declaration to count, or an ordinary statement in a function
--  body would be paired. The signal that needs no list of statement kinds
--  is a `name` field, which a declaration has and a statement does not; a
--  list of further node types, verified against a real file, covers a
--  declaration its grammar did not give a name field.
--
--  A pair's kind is the declaration's raw node type, and its name is its first
--  line of text: nothing here agrees with `tags.scm` on what a kind is, and a
--  changed signature is exactly the edit that should make a docstring worth
--  reading again.

package Synapse.Adapters.Tree_Sitter.Docstring_Pairs with
  SPARK_Mode => Off
is

   subtype Pair is Synapse.Ports.Docstring_Pairs.Pair;

   package Pair_Vectors renames Synapse.Ports.Docstring_Pairs.Pair_Vectors;

   type Pair_Error is (Language_Rejected, Not_Parsed);

   package Pair_Results is new Synapse.Core.Results
     (Pair_Vectors.Vector, Pair_Error);

   --  Every pair in Source at any depth, in source order, a node's own before
   --  those below it. Comment_Type is the node type of a comment; Extra_Kinds
   --  are node types that count as declarations without a `name` field.
   function Find_Pairs
     (Lang        : Language; Source : String; Comment_Type : String;
      Extra_Kinds : Core.Text_Lists.Vector) return Pair_Results.Result with
     Pre => not Is_Null (Lang);

   --  The comment node type of an extension: `<ext>.comments.scm` in the
   --  override directory when it names one, else the default. A file that is
   --  absent, unreadable or longer than 4,096 bytes names none.
   function Comment_Type_Name
     (Override_Dir : Core.Grammar_Registry.Maybe_Text; Extension : String)
      return String;

   --  The extra declaration kinds of an extension, from
   --  `<ext>.declarations.scm`. None when there is no such file.
   function Declaration_Overrides
     (Override_Dir : Core.Grammar_Registry.Maybe_Text; Extension : String)
      return Core.Text_Lists.Vector;

end Synapse.Adapters.Tree_Sitter.Docstring_Pairs;
