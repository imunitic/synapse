with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Namespace;
with Synapse.Core.Text_Lists;
with Synapse.Ports.Repo_Reader;

--  `_deps.tsv`: each tracked file's own declared build or import dependencies,
--  one `path <TAB> library` row for each, the signal that tells a name defined
--  in more than one node which one a reference means: a symbol defined in more
--  than one node is not rare, it is ambiguous.
--
--  Its own artifact and not a column of the refs index: this is a row per
--  file, the refs index is a row per occurrence of a reference, and repeating
--  a fact about a file on every row from it would burden every consumer of the
--  refs index, including those that do not care about imports.
--
--  The extraction is the namespace extraction (a prefix and a terminator, in
--  the file or in the nearest ancestor build file), answering "what does this
--  file depend on" and not "what is it". It has its own configuration file,
--  `synapse-dependency-rules.conf`, and not a second key on the namespace one:
--  an extension can need both facts at once, and one rule per extension leaves
--  no room for two. Like it, it ships no rule: a rule is written after it has
--  been checked against a real file of the repository.

package Synapse.Core.Deps is

   use Ada.Strings.Unbounded;

   --  One file-depends-on-library edge.
   type Row is record
      Path    : Unbounded_String;
      Library : Unbounded_String;
   end record;

   type Maybe_Row (Found : Boolean := False) is record
      case Found is
         when True =>
            Value : Row;

         when False =>
            null;
      end case;
   end record;

   --  `path <TAB> library`. A truncated line is none and not an error, as for
   --  the refs index: the artifact is derived and rebuilt.
   function Parse_Row (Line : String) return Maybe_Row;

   --  The raw declared value split into names. White space covers a build-file
   --  rule whose value is a list, and a comma is accepted so that a rule for a
   --  comma-separated import list needs only a configuration entry. A single
   --  name comes back as one token either way.
   function Split_Libraries (Raw : String) return Text_Lists.Vector;

   package Row_Vectors is new Ada.Containers.Vectors (Positive, Row);

   --  A row per declared dependency across every path of Kept whose extension
   --  has a rule, path ascending and library ascending within a path, so two
   --  runs over an unchanged repository are identical. An empty registry
   --  returns at once without reading a file.
   function Compute
     (Reader : in out Ports.Repo_Reader.Reader'Class; Kept : Text_Lists.Vector;
      Rules  :        Namespace.Registry) return Row_Vectors.Vector;

   --  `path <TAB> library` and a line feed.
   function Image (R : Row) return String;

end Synapse.Core.Deps;
