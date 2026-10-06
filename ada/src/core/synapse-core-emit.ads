with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Graph_Model;
with Synapse.Core.Node_Format;
with Synapse.Core.Text_Lists;

--  Emitting a node: the directives a body carries, and the bytes that come
--  out.
--
--  Central rule: the body points, the writer slices. A body carries
--
--    <!-- crux: path/to/file 412-419 -->
--    <!-- grounded_in: path/to/file 10-14 -->
--
--  and never the code itself, so a crux cannot be a paraphrase that merely
--  looks like a quote. They are HTML comments so an unexpanded directive
--  renders as nothing and not as a broken code block.
--
--  The two diverge after slicing: a crux is display (fenced into the body
--  with a provenance line under it); a grounding is provenance (only its
--  path, lines and SHA-256 reach the frontmatter, and the directive is
--  stripped from the body: six groundings as six code blocks would bury the
--  prose).
--
--  Everything here is a function of text. Reading files, hashing with git,
--  resolving the namespace and storing the result need the world and are the
--  command's job.
--
--  Range checks (claimed path, inside the file, not too long) refuse a write
--  and never degrade it: each would otherwise produce a plausible node that
--  is wrong, with code the node does not cover, a slice of a file that
--  shrank, or a whole function where a decision was asked for.

package Synapse.Core.Emit is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   type Maybe_Text (Found : Boolean := False) is record
      case Found is
         when True =>
            Text : Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  A file name the vault can store. A wikilink resolves by file name, so
   --  a sanitized title silently breaks every inbound link: this returns the
   --  sanitized form for the caller to compare and warn on, and never renames
   --  quietly.
   function File_Title (Title : String) return String with
     Post => File_Title'Result'Length = Title'Length;

   --  A `path first-last` directive argument, parsed.
   type Span is record
      Path        : Unbounded_String;
      First, Last : Natural;
   end record;

   --  The number of lines in the span, inclusive.
   function Lines (Of_Span : Span) return Natural is
     (Of_Span.Last - Of_Span.First + 1) with
     Pre => Of_Span.Last >= Of_Span.First;

   type Maybe_Span (Found : Boolean := False) is record
      case Found is
         when True =>
            Value : Span;

         when False =>
            null;
      end case;
   end record;

   --  What a `crux:` directive said. `none` is a real answer: a node whose
   --  logic is spread across files says so and gets a rendered line, and is
   --  not refused.
   type Crux_Directive (Is_Span : Boolean := False) is record
      case Is_Span is
         when True =>
            Where : Span;

         when False =>
            null;
      end case;
   end record;

   Kind_Crux     : constant String := "crux";
   Kind_Grounded : constant String := "grounded_in";

   --  The first `<!-- keyword: ... -->` in Text, returned whole: the caller
   --  needs the same bytes back to find its line again. A comment that is not
   --  that directive is prose, and `cruxes are nice` is not `crux:`.
   function Find_Directive (Text, Keyword : String) return Maybe_Text;

   --  Every `<!-- keyword: ... -->` in Text, in order, each whole.
   --  `grounded_in` is repeatable.
   function Directives (Text, Keyword : String) return Text_Lists.Vector;

   --  The part after `keyword:`, trimmed, of the text inside a comment; none
   --  when the comment is a different directive or not one at all. Every
   --  comment Find_Directive and Directives return parses here.
   function Directive_Arg (Inner, Keyword : String) return Maybe_Text;

   --  The text under a `## heading` line, up to the next `## ` heading or the
   --  generated-region end marker, whichever comes first; none if the heading
   --  is not there. Only a line that is exactly the heading counts, never a
   --  longer heading that starts with it. It exists to scope a directive
   --  search to the one section it lives in, so prose elsewhere that
   --  describes the syntax is not mistaken for the real thing.
   function Section (Text, Heading : String) return Maybe_Text with
     Pre => Heading'Length <= 125;

   --  A directive argument as a span. An `L` is tolerated in front of either
   --  bound (how a range is copied from an editor gutter), and `10-20-30`
   --  reads as 10 to 30. The two bounds are digits and nothing else: a sign
   --  would turn a typo into a valid range. A number too large to be a line
   --  is clamped, so it reads as out of range and not as malformed.
   function Parse_Span (Arg : String) return Maybe_Span;

   --  Which directive a span came from, and so how long it may be.
   type Span_Kind is (Crux, Grounded);

   --  Most lines a span of the kind may carry. A grounding is roomier on
   --  purpose: a doc comment or a test body is legitimately longer than the
   --  few lines that carry a decision.
   function Cap (Of_Kind : Span_Kind) return Positive is
     (case Of_Kind is when Crux => 20, when Grounded => 40);

   function Keyword (Of_Kind : Span_Kind) return String is
     (case Of_Kind is when Crux => Kind_Crux, when Grounded => Kind_Grounded);

   type Problem_Kind is (None, Not_Claimed, Out_Of_Range, Too_Long);

   type Span_Problem (Kind : Problem_Kind := None) is record
      case Kind is
         when Out_Of_Range =>
            Total_Lines : Natural;  --  the file's line count

         when Too_Long =>
            Line_Count : Natural;  --  the span's, inclusive

         when None | Not_Claimed =>
            null;
      end case;
   end record;

   --  What is wrong with a span, or None. Paths must be sorted bytewise and
   --  without duplicates. Total_Lines is a line-feed count (see
   --  Line_Slice.Count_Lines): a final line with no terminator is not
   --  countable, so a range ending on it is refused.
   function Check_Span
     (Of_Span     : Span; Of_Kind : Span_Kind; Paths : Text_Lists.Vector;
      Total_Lines : Natural) return Span_Problem;

   --  What replaces a `crux:` directive line: a fenced slice and a provenance
   --  line. Sliced ends with a line feed unless the file did not; the closing
   --  fence gets its own line either way. Lang is the fence language the
   --  caller resolved, empty for a bare fence.
   function Crux_Block (Of_Span : Span; Sliced, Lang : String) return String;

   --  The line a `<!-- crux: none -->` expands to.
   Crux_None_Text : constant String :=
     "_No single span carries this node's logic._";

   --  Text with the first line that contains Marker replaced, the whole line
   --  and not just the marker, so an indented comment leaves no stray blank
   --  line. Trailing line feeds of Replacement are dropped.
   function Substitute_Line
     (Text, Marker, Replacement : String) return String with
     Pre => Marker'Length > 0;

   --  Text without any `grounded_in` directive: a line that is only a
   --  directive disappears, and one inside prose is cut out of it without
   --  deleting the sentence around it.
   function Strip_Grounded (Text : String) return String;

   --  The text without leading and trailing blank lines. A body is recovered
   --  from a node and written back on every reseat, and without this it
   --  gathers a blank line per rebuild.
   function Trim_Blank_Edges (Text : String) return String;

   --  The contents of a double-quoted YAML scalar: backslash and quote are
   --  escaped, and so are line breaks. Every frontmatter reader scans line by
   --  line with no notion of a scalar folding across lines, so a raw line
   --  break in a title would read back as a new `key: value` line.
   function Yaml_Quoted (Text : String) return String;

   --  The crux's own pointer, recorded beside the sliced text.
   type Crux_Pointer is record
      Path  : Unbounded_String;
      Lines : Unbounded_String;  --  `first-last`
   end record;

   --  One `grounded_in:` row of the frontmatter.
   type Grounded_Row is record
      Path   : Unbounded_String;
      Lines  : Unbounded_String;  --  `first-last`
      --  SHA-256 of the slice. `digest:` and never `hash:`: `sources:` uses
      --  `hash:`, and confusing the two finds nothing.
      Digest : Unbounded_String;
   end record;

   package Grounded_Vectors is new Ada.Containers.Vectors
     (Positive, Grounded_Row);

   --  Everything the note is made of, already computed.
   type Note is record
      Title, Summary : Unbounded_String;
      Project        : Unbounded_String;
      Branch         : Unbounded_String;
      --  Sorted bytewise and without duplicates, with their blob hashes.
      Sources        : Graph_Model.Source_Vectors.Vector;
      --  64 hex digits from Node_Format.Sources_Digest.
      Digest         : Unbounded_String;
      Built_At       : Unbounded_String;
      --  Empty omits the field: a present but blank `commit:` would be read
      --  as a baseline.
      Commit         : Unbounded_String;
      Has_Crux       : Boolean := False;
      Crux           : Crux_Pointer;
      Grounded       : Grounded_Vectors.Vector;
      --  Grouped and sorted bytewise by module name.
      Modules        : Node_Format.Module_Count_Vectors.Vector;
      --  Expanded, stripped and about to be trimmed.
      Prose          : Unbounded_String;
      --  Everything after the closing fence of the existing node, trailing
      --  line feeds dropped. Empty starts a fresh `## Notes`; otherwise it is
      --  written back verbatim on every rewrite, which is why hand-written
      --  notes survive a regeneration nobody reviews.
      Tail           : Unbounded_String;
   end record;

   --  Fewer sources than this and `## Sources` lists each path; at or above
   --  it, the module rollup. A handful of files reads better as an exact list
   --  than as `module (1)` rows that hide which file it is.
   Sources_Path_Threshold : constant := 5;

   --  The note as text. The field order is fixed, and the schema of a graph
   --  node requires it: the short scalar fields come first and `sources` is
   --  always last, so a single-key lookup that stops at the first matching
   --  line never has a long sources list in front of it.
   function Image (Of_Note : Note) return String;

   --  The text with its one `stale:` line set to `stale: true`, and every
   --  other byte, a line-ending style included, as it was. Changed is False
   --  when the node was already stale or has no frontmatter, so the caller
   --  can skip the write. A node without the field gains it before the
   --  closing marker. It rewrites a line and never re-serializes the
   --  frontmatter, which would strip quotes and coerce values: an all-digit
   --  hash becomes a float, and `sources_digest` is desynchronized for good.
   procedure Set_Stale_True
     (Text : String; Result : out Unbounded_String; Changed : out Boolean);

   --  The text inside ``` fences, concatenated: the node's own copy of its
   --  crux. A toggle and not a parser, so several fenced blocks all
   --  contribute.
   function Fenced_Text (Text : String) return String;

   --  The hand-written `## Notes` body: what follows the closing fence, minus
   --  its own heading and surrounding blank lines. Empty means nothing is at
   --  risk in a rebuild. A differently worded heading is content, since
   --  something wrote it deliberately.
   function Notes_Body (Text : String) return String;

end Synapse.Core.Emit;
