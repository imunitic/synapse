with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Ports.Search_Filtered;
with Synapse.Ports.Store;

--  A Store of Markdown files in a directory tree: the vault.
--
--  A node N is the file `Vault/Namespace/N`, or `Vault/N` for an empty
--  namespace. A node name that is not safe (see Core.Node_Path) raises
--  Unsafe_Node.

package Synapse.Adapters.Disk_Store is

   package Port renames Synapse.Ports.Store;
   package Filtered renames Synapse.Ports.Search_Filtered;

   type Disk_Store is
     limited new Port.Store and Filtered.Searchable with private;

   function Create (Vault, Namespace : String) return Disk_Store;

   --  Nothing when there is no file; Store_Failure for a directory, a file
   --  over 256 MiB, or any other failure to read.
   overriding
   function Read (S : in out Disk_Store; Node : String) return Port.Maybe_Text;

   --  Creates the directories the node needs and replaces the file in one
   --  step (see Replace_File), so a reader never sees a partial note.
   overriding
   function Write
     (S : in out Disk_Store; Node, Content : String) return Port.Write_Result;

   --  Every `.md` file under the namespace directory, recursively, as paths
   --  relative to it, sorted bytewise. A directory or file whose name starts
   --  with a dot (`.git`, `.obsidian`) is skipped, and a missing namespace
   --  directory lists as empty.
   overriding
   function List (S : in out Disk_Store) return Core.Text_Lists.Vector;

   --  The words that are not worth searching for (see Core.Words.Keep). None
   --  until set.
   procedure Set_Stopwords
     (S : in out Disk_Store; Words : Core.Text_Lists.Set);

   --  Search_Filtered with no filter.
   overriding
   function Search
     (S : in out Disk_Store; Query : String) return Port.Hit_Vectors.Vector;

   --  Ranks the nodes that pass Filter (all of them with no filter; a node
   --  that fails is not read). The query is split into terms
   --  (Core.Words.Query_Terms); a node's score is how often each term occurs
   --  in its text after the frontmatter, case folded, weighted by how rare
   --  the term is among the candidates. Nodes with a score of zero are left
   --  out, the rest ordered by score, best first, and then by name; a hit's
   --  context is the first line holding any term. A query with no usable
   --  term (every word short, all digits or a stopword) is counted whole as
   --  a plain substring instead.
   overriding
   function Search_Filtered
     (S      : in out Disk_Store;
      Query  : String;
      Filter : Filtered.Path_Filter) return Port.Hit_Vectors.Vector;

private

   type Disk_Store is
     limited new Port.Store and Filtered.Searchable with record
      Vault     : Ada.Strings.Unbounded.Unbounded_String;
      Namespace : Ada.Strings.Unbounded.Unbounded_String;
      Stopwords : Core.Text_Lists.Set;
   end record;

end Synapse.Adapters.Disk_Store;
