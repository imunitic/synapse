with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Text_Lists;
with Synapse.Ports.Store;

--  Structured querying of a store with a JsonLogic filter: list the nodes,
--  read each candidate, and evaluate the filter against it. Not a store
--  operation and not per backend, since the filtering is the same whatever
--  the rows came from.
--
--  A result row is a small explicit projection: the note's path and only the
--  fields the caller named. Never the whole text as a side effect of
--  filtering, which would be too much to put in front of a reader, and not so
--  little that answering a question needs a second read of every match.
--
--  A filter sees `path`, `content`, `frontmatter.*` and `tags`. Links and
--  backlinks would need an index of the whole vault and are not here.

package Synapse.Core.Vault_Query is

   use Ada.Strings.Unbounded;

   package Value_Vectors is new Ada.Containers.Vectors
     (Positive, JSON.Value, JSON."=");

   --  One matching note: its path and one value for each field asked for, in
   --  the order asked.
   type Row is record
      Path   : Unbounded_String;
      Values : Value_Vectors.Vector;
   end record;

   package Row_Vectors is new Ada.Containers.Vectors (Positive, Row);

   --  Runs Filter against every node the store lists, in list order. A note
   --  for which the filter is falsy is left out, and so is one whose
   --  evaluation fails (an unknown operator): it just does not match. For
   --  each match every field is read as `{"var": field}`, a field that cannot
   --  be evaluated or is not there reading as null. Fields may be empty,
   --  giving only the paths.
   --
   --  A clause of a top-level `and` that mentions nothing but `path`, or a
   --  filter that does so as a whole, is tried on the name alone first: a
   --  node it rules out is never read.
   function Query
     (Source : in out Synapse.Ports.Store.Store'Class; Filter : JSON.Value;
      Fields :        Text_Lists.Vector) return Row_Vectors.Vector;

   --  Whether a filter that mentions only `path` matches Name, with no note
   --  text available to it. An evaluation failure is no match, the same
   --  "cannot tell, so it is out" rule the full filter follows.
   function Path_Matches (Filter : JSON.Value; Name : String) return Boolean;

   --  `{path, content, frontmatter, tags}`: everything a filter in this vault
   --  has had to match on. `tags` is also reachable as `frontmatter.tags`.
   function Note_Data (Path, Text : String) return JSON.Value;

end Synapse.Core.Vault_Query;
