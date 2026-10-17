with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Ports.Link_Graph;

--  The link graph of the Markdown files of a vault directory, computed from
--  the files on every call. Always the whole vault, never one namespace: a
--  link can point anywhere. The `synapse/` directory, which holds the code
--  graph with its own links, is left out of it entirely.
--
--  A link resolves, in this order, to:
--  * the note whose `note_id` (else `task_id`) is the link's target, exactly,
--    the first such note by path winning a repeated id;
--  * every note whose title (its file name without `.md`) is the same title
--    as the target after Unicode NFC and simple case folding.
--  The target is first reduced to a title: without a leading path, a `#`
--  anchor and `.md`.

package Synapse.Adapters.Disk_Link_Graph is

   package Port renames Synapse.Ports.Link_Graph;

   type Disk_Link_Graph is limited new Port.Link_Graph with private;

   function Create (Vault : String) return Disk_Link_Graph;

   overriding
   function Backlinks
     (G : in out Disk_Link_Graph; Node : String)
      return Port.Backlink_Vectors.Vector;

   overriding
   function Links
     (G : in out Disk_Link_Graph; Node : String)
      return Core.Text_Lists.Vector;

   overriding
   function Unresolved_Links
     (G : in out Disk_Link_Graph) return Port.Unresolved_Vectors.Vector;

   overriding
   function Ambiguous_Links
     (G : in out Disk_Link_Graph) return Port.Ambiguous_Vectors.Vector;

   overriding
   function Orphans (G : in out Disk_Link_Graph)
      return Core.Text_Lists.Vector;

   overriding
   function Dead_Ends (G : in out Disk_Link_Graph)
      return Core.Text_Lists.Vector;

private

   type Disk_Link_Graph is limited new Port.Link_Graph with record
      Vault : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Adapters.Disk_Link_Graph;
