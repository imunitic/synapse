with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Ports.Byte_Source;

--  `_refs.tsv`: a flat, bytewise sorted reference index, and the lookup over
--  it. One line per tag, so "who calls X" is a text lookup and not a
--  traversal:
--
--    name <TAB> def|ref <TAB> kind <TAB> path:line <TAB> expression
--
--  Both the role and the kind are kept: a `ref` is not necessarily a call
--  (`implements Foo` is a reference of kind `implementation`), so filtering on
--  the role alone over-reports.
--
--  The file is searched by bisection over a byte source, reading the few
--  blocks the search lands on and never the whole index, which on a large
--  repository runs to a gigabyte. Names match exactly and not by prefix:
--  looking up `bet` does not return every `beta`.

package Synapse.Core.Refs is

   use Ada.Strings.Unbounded;

   type Row is record
      Name : Unbounded_String;
      --  `def` or `ref`.
      Dir  : Unbounded_String;
      --  `class`, `method`, `call`, `implementation`, ...
      Kind : Unbounded_String;
      --  `path:line`, one field: what a person pastes into an editor.
      Site : Unbounded_String;
      --  The source line the tag came from, usually enough to settle a
      --  receiver without opening the file.
      Expr : Unbounded_String;
   end record;

   --  A call site: a reference whose kind is `call`. Not every reference is
   --  one.
   function Is_Call (R : Row) return Boolean is
     (To_String (R.Dir) = "ref" and then To_String (R.Kind) = "call");

   type Maybe_Row (Found : Boolean := False) is record
      case Found is
         when True =>
            Value : Row;

         when False =>
            null;
      end case;
   end record;

   --  A line as a row; none when it has too few fields. A truncated line, from
   --  an interrupted write, is skipped and not fatal: the index is derived and
   --  rebuilt. The expression is the whole remainder, so a column added
   --  upstream does not lose text.
   function Parse_Row (Line : String) return Maybe_Row;

   package Row_Vectors is new Ada.Containers.Vectors (Positive, Row);

   --  A bisection touches a block for each step, so a small one is much
   --  cheaper: 4 KB lookups in an 800 MB index are ten times faster than
   --  64 KB ones. A line longer than the block is read with a longer read.
   Default_Block : constant := 4_096;

   --  Every row whose name is exactly Name, in index order. The index must be
   --  the whole file, bytewise sorted: what Sort_Unique produces. Block is how
   --  much is read at a time. A lone final line with no line feed counts.
   function Find
     (Index : in out Ports.Byte_Source.Source'Class; Name : String;
      Block :        Positive := Default_Block) return Row_Vectors.Vector;

   --  Every row of the index in order, one block at a time, so that a table of
   --  a gigabyte is never held whole. A line that is not a row is skipped.
   generic
      with procedure Visit (R : Row);
   procedure For_Each_Row
     (Index : in out Ports.Byte_Source.Source'Class;
      Block :        Positive := Default_Block);

   type Counts is record
      Tags  : Natural := 0;
      Defs  : Natural := 0;
      Refs  : Natural := 0;
      --  Distinct paths, not distinct rows: rows are sorted by name, so one
      --  file recurs throughout.
      Files : Natural := 0;
   end record;

   type Sorted_Index is record
      Text  : Unbounded_String;
      Tally : Counts;
   end record;

   --  The lines of Unsorted in bytewise order, each once and ending in a line
   --  feed, with what survived counted. Empty lines are dropped. Two
   --  identical tags on one line of one file are one fact.
   function Sort_Unique (Unsorted : String) return Sorted_Index;

end Synapse.Core.Refs;
