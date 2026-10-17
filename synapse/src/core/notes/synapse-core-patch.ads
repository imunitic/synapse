with Ada.Strings.Unbounded;

with Synapse.Core.Results;
with Synapse.Core.Text_Lists;

--  A targeted partial update of a note: splicing text at a heading, a block or
--  a frontmatter key. Built over the whole text of a note and not over a
--  store, since the splice is the same wherever the bytes came from: read the
--  note, splice, write the whole result back.
--
--  A frontmatter target is `Frontmatter.Edit.Set_Scalar`, already byte
--  preserving, whatever the operation. This package adds the heading and
--  block splicing a frontmatter edit never needed.

package Synapse.Core.Patch is

   use Ada.Strings.Unbounded;

   type Target_Kind is (Heading, Block_Id, Frontmatter_Key);

   type Target (Kind : Target_Kind := Heading) is record
      case Kind is
         when Heading =>
            --  The heading texts from the top down, such as `Notes` and
            --  `Implementation`: a heading under a parent of the same name as
            --  another heading is told apart by its path.
            Path : Text_Lists.Vector;

         when Block_Id | Frontmatter_Key =>
            --  A block id without its `^`, or a frontmatter key.
            Name : Unbounded_String;
      end case;
   end record;

   --  Rename relabels the heading line and nothing in its section, so it has
   --  no append or prepend form and applies only to a heading.
   type Operation is (Append, Prepend, Replace, Rename);

   type Error_Kind is
     (Target_Not_Found,
      --  A frontmatter target in a note with no frontmatter block.
      No_Frontmatter,
      --  Rename against a block or a frontmatter key, neither of which has a
      --  title to relabel.
      Invalid_Operation_For_Target,
      --  A heading is always one line.
      Multiline_Heading_Text,
      --  More text than a frontmatter edit takes.
      Too_Large);

   package Results is new Synapse.Core.Results (Unbounded_String, Error_Kind);

   --  The whole new note after applying Op with Content at Where in Text.
   --  Create_If_Missing creates a missing heading (and any missing ancestors,
   --  each a level deeper than its parent) and means nothing else: a missing
   --  frontmatter key is always inserted, and a missing block cannot be
   --  created, since there is no sensible place for an id no content carries.
   --
   --  Append and Prepend splice Content verbatim, so a caller supplies its own
   --  newlines. A section's blank line before the next heading is part of the
   --  note's structure and not of the section: a replace or an append never
   --  consumes it. Headings in a fenced code block are not headings. A block
   --  is a single line ending in ` ^id`.
   function Apply
     (Text : String; Where : Target; Op : Operation; Content : String;
      Create_If_Missing : Boolean) return Results.Result;

   --  Every target that is valid in a note, so a caller can pick one and not
   --  guess it.
   type Document_Map is record
      --  `::` joined heading paths in document order, each usable as it is as
      --  a heading target.
      Headings         : Text_Lists.Vector;
      --  Block ids without the `^`, in document order.
      Blocks           : Text_Lists.Vector;
      --  Frontmatter keys at the top level, in document order.
      Frontmatter_Keys : Text_Lists.Vector;
   end record;

   function Map_Of (Text : String) return Document_Map;

end Synapse.Core.Patch;
