with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;

--  A vault's own graph of links between notes: what links to a note, what it
--  links to, and what is broken, ambiguous, unlinked or a dead end. A
--  separate capability from the store: a store opts into it, and none is made
--  to stub one. Every list is ordered by name, so callers can rely on it.

package Synapse.Ports.Link_Graph is

   use Ada.Strings.Unbounded;

   --  A note that links to another, and how many of its links do.
   type Backlink is record
      Node  : Unbounded_String;
      Count : Natural;
   end record;

   --  A link target that names no note, how many links use it and which notes
   --  contain them.
   type Unresolved is record
      Target  : Unbounded_String;
      Count   : Natural;
      Sources : Core.Text_Lists.Vector;
   end record;

   --  A link target that names more than one note: the same as Unresolved
   --  with the notes it could mean.
   type Ambiguous is record
      Target     : Unbounded_String;
      Candidates : Core.Text_Lists.Vector;
      Count      : Natural;
      Sources    : Core.Text_Lists.Vector;
   end record;

   package Backlink_Vectors is new Ada.Containers.Vectors (Positive, Backlink);
   package Unresolved_Vectors is new
     Ada.Containers.Vectors (Positive, Unresolved);
   package Ambiguous_Vectors is new
     Ada.Containers.Vectors (Positive, Ambiguous);

   type Link_Graph is limited interface;

   --  The notes with a link to Node, with their counts, by name.
   function Backlinks
     (G : in out Link_Graph; Node : String) return Backlink_Vectors.Vector
   is abstract;

   --  The notes Node links to, each once, in the order they are first linked.
   function Links
     (G : in out Link_Graph; Node : String) return Core.Text_Lists.Vector
   is abstract;

   --  Links that name no note, by target.
   function Unresolved_Links
     (G : in out Link_Graph) return Unresolved_Vectors.Vector
   is abstract;

   --  Links that name several notes, by target. Every candidate counts as
   --  linked to; none is guessed.
   function Ambiguous_Links
     (G : in out Link_Graph) return Ambiguous_Vectors.Vector
   is abstract;

   --  The notes nothing links to.
   function Orphans (G : in out Link_Graph) return Core.Text_Lists.Vector
   is abstract;

   --  The notes with no link that leads to a note. A note whose only links
   --  are unresolved is one.
   function Dead_Ends (G : in out Link_Graph) return Core.Text_Lists.Vector
   is abstract;

end Synapse.Ports.Link_Graph;
