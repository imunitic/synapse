with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Ports.Store;

--  A Store of Markdown files in a directory tree: the vault.
--
--  A node N is the file `Vault/Namespace/N`, or `Vault/N` for an empty
--  namespace. A node name that is not safe (see Core.Node_Path) raises
--  Unsafe_Node.

package Synapse.Adapters.Disk_Store is

   package Port renames Synapse.Ports.Store;

   type Disk_Store is limited new Port.Store with private;

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

   --  The nodes whose text after the frontmatter contains Query under case
   --  folding, scored by the number of occurrences, best first and then by
   --  name, with the first matching line as context.
   overriding
   function Search
     (S : in out Disk_Store; Query : String) return Port.Hit_Vectors.Vector;

private

   type Disk_Store is limited new Port.Store with record
      Vault     : Ada.Strings.Unbounded.Unbounded_String;
      Namespace : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Adapters.Disk_Store;
