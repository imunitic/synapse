with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Node_Format;
with Synapse.Core.Text_Lists;
with Synapse.Core.Text_Search;

--  Reading a node: the parts that are a function of its text alone. The
--  fields of its frontmatter, the source list, the body between the
--  generated fences, the `## Links` edges and the module counts. What needs
--  the world (staleness, drift) is not here.

package Synapse.Core.Node_Query is

   use Ada.Strings.Unbounded;

   type Maybe_Text (Found : Boolean := False) is record
      case Found is
         when True =>
            Text : Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  The prose a node is for: between the generated fences, without the two
   --  marker lines. Exactly one line feed comes off each end, the one that
   --  ended the start marker and the one that ended the last line before the
   --  end marker, so the blank line a node has between the start marker and
   --  its first heading survives: a body is quoted into prose elsewhere, and
   --  a missing blank line there is a rendering change. Between the fences
   --  and not after the frontmatter, so neither the frontmatter nor the
   --  hand-written `## Notes` is in it. None for a node with no fence.
   function Body_Of (Text : String) return Maybe_Text;

   --  Everything after the frontmatter: what a caller reads for a node with
   --  no fence, `## Notes` included, which is worth announcing.
   function Body_After_Frontmatter (Text : String) return String;

   --  What a default query prints: the frontmatter `summary` (unescaped), the
   --  crux as a `path:lines` pointer and never the quoted code, and the
   --  `## Links` block: the three things that say what a node is and where to
   --  read next. A part the node lacks is left out. None for a node with no
   --  fence, which the caller prints as the whole body.
   function Brief (Text : String) return Maybe_Text;

   type Maybe_Ranges (Valid : Boolean := False) is record
      case Valid is
         when True =>
            Ranges : Text_Search.Range_Vectors.Vector;

         when False =>
            null;
      end case;
   end record;

   --  `12-14,40-41,88` as ranges, in the order given: the spelling
   --  Text_Search.Image produces. Invalid for anything malformed: an empty
   --  item, a non-number, a sign, a zero line, an end before its start. A
   --  number too large to be a line is clamped.
   function Parse_Line_Ranges (Spec : String) return Maybe_Ranges;

   --  The lines of Text in each range, in the order given, numbered as in the
   --  file, frontmatter included, each ending in a line feed. An end past the
   --  last line stops at the last line. None when a range starts past it.
   function Lines_In
     (Text : String; Ranges : Text_Search.Range_Vectors.Vector)
      return Maybe_Text;

   --  One top-level frontmatter scalar as written: at most one quote removed
   --  from each end, escapes left alone, which is what a field query prints.
   --  None when the key is absent. The frontmatter ends at its closing fence,
   --  so prose in the body that looks like a key is not one.
   function Field (Text, Key : String) return Maybe_Text;

   --  One frontmatter scalar as a YAML reader sees it: the escapes the writer
   --  produces (`\\` and `\"`) undone. A bare value means what it says and is
   --  returned as written. None when the key is absent.
   function Scalar (Text, Key : String) return Maybe_Text;

   --  The `- path:` values of the `sources:` block, in file order. Scoped to
   --  that block: `grounded_in:` rows are `- path:` pairs too, and a
   --  grounding's path is one of the node's own sources, so an unscoped match
   --  would count it twice and make a digest that never equals the stored
   --  one.
   function Sources (Text : String) return Text_Lists.Vector;

   --  Source paths grouped by module, sorted bytewise by module name: the
   --  output is read as a table and not as a ranking. Empty paths are
   --  skipped.
   function Module_Counts
     (Paths : Text_Lists.Vector; Chains : Text_Lists.Vector)
      return Node_Format.Module_Count_Vectors.Vector;

   --  One `## Links` edge.
   type Edge is record
      Relation : Unbounded_String;
      Target   : Unbounded_String;
   end record;

   package Edge_Vectors is new Ada.Containers.Vectors (Positive, Edge);

   --  The outbound edges of one node, in file order. A line is an edge when
   --  it is `- relation [[target]]`: the relation is everything between the
   --  dash and the link and is not empty (a link with no relation says
   --  nothing about how two nodes relate), the target is what the brackets
   --  hold, display text after a `|` included. The section ends at the next
   --  `## ` heading.
   function Edges (Text : String) return Edge_Vectors.Vector;

end Synapse.Core.Node_Query;
