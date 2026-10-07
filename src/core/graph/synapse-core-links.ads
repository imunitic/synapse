with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Ports.Byte_Source;

--  The node-to-node link graph, computed before any prose exists.
--
--  A node's `## Links` section is typed relations and not prose. Two of the
--  three types are reference relations that the code cache already holds, and
--  node titles exist before any prose is written, so the join needs no summary
--  first: the refs index gives `name -> def | ref -> path:line`, a map from
--  path to node gives `path -> node`, and a reference in one node's file that
--  names a definition in another is an edge. `part_of` stays a human
--  judgement: containment is not in the refs index.
--
--  Rarity, counted and not summed. A symbol referenced from few nodes is
--  informative; one referenced from thirty says nothing about either end of
--  the edge. The most nodes that may reference a symbol for it to count is
--  `Rarity.Rare_Max`. An edge's weight is how many distinct rare symbols
--  support it, and not a sum of inverse document frequencies: what separates a
--  real concept from a generic one is whether it has distinctive vocabulary at
--  all, and not how much.
--
--  A symbol defined in more than one node is not rare, it is ambiguous.
--  Joining by bare name (the index carries no receiver or type) would fan an
--  edge from every reader of a common name to every node that defines it, most
--  pointing at the wrong one. A name with exactly one definer is unambiguous
--  by construction; one defined more than once contributes no edges, since the
--  false edges a wrong guess would add cost more than the true ones a right
--  guess would keep.
--
--  Resolve_Ambiguous recovers some of what that costs, for the one case with a
--  real signal beyond the bare name: a reference whose own file declares a
--  dependency on exactly one candidate definition's library. It is a heuristic
--  over syntax and not semantic analysis, so it narrows the candidates and
--  never guarantees: a name that stays ambiguous even then is left alone.

package Synapse.Core.Links is

   use Ada.Strings.Unbounded;

   --  One candidate edge: From references something To defines, by way of
   --  Symbols, all of which cleared the rarity bar. Weight is how many there
   --  were, before Symbols was cut to the number shown: the list is capped for
   --  readability, the weight is not.
   type Edge is record
      From    : Unbounded_String;
      To      : Unbounded_String;
      Weight  : Natural;
      Symbols : Text_Lists.Vector;
   end record;

   package Edge_Vectors is new Ada.Containers.Vectors (Positive, Edge);

   type Options is record
      --  Edges kept per From node, strongest first. 0 means no cap.
      Top           : Natural := 8;
      --  Symbol names shown per edge, alphabetical among equals, since none of
      --  them outranks another once both are rare. 0 means no cap.
      Symbols_Shown : Natural := 5;
   end record;

   Default_Options : constant Options := (Top => 8, Symbols_Shown => 5);

   --  Path to the titles of the nodes that claim it: several for a path more
   --  than one subsystem cites.
   package Path_Nodes is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Text_Lists.Vector, "<", Text_Lists.Vectors."=");

   --  Path to a set of strings: what a file declares itself to be, or what it
   --  declares it depends on.
   package Path_Sets is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Text_Lists.Set, "<", Text_Lists.Sets."=");

   --  Joins the refs index with Path_To_Nodes and returns every node's
   --  strongest outgoing edges: From ascending, Weight descending, To
   --  ascending, a total order, so two runs over an unchanged repository are
   --  identical. Node_Count is N of the rarity floor: every node of the
   --  manifest, not just those that appear in Path_To_Nodes. A row whose path
   --  claims no node contributes nothing, and neither does a symbol with no
   --  definition, one defined by more than one node, or one referenced by more
   --  nodes than the floor allows.
   function Compute
     (Refs          : in out Ports.Byte_Source.Source'Class;
      Path_To_Nodes :        Path_Nodes.Map; Node_Count : Natural;
      Opts          : Options := Default_Options) return Edge_Vectors.Vector;

   --  Recovers an edge for a name Compute dropped for being defined by more
   --  than one node, from two facts per file that Compute never uses: what
   --  each candidate definition's file declares itself to be (a set, since
   --  a rule's aliases can give a file more than one valid name) and what each
   --  referencing file declares it depends on. A reference in file A resolves
   --  to a candidate in file D only when exactly one of D's identities is in
   --  A's dependencies; two qualifying candidates are still ambiguous. The
   --  signal is real and not a guarantee: a file can declare a dependency it
   --  never uses for this symbol.
   --
   --  A reference whose own node also defines the name is never resolved to
   --  another node, whatever its file depends on: lexical scoping makes the
   --  definition in the same node almost always the true answer.
   --
   --  The same Edge as Compute, ordered and capped alike, and meant to be
   --  merged with it. There is deliberately no rarity ceiling on the name: the
   --  discriminating signal is the file's own dependency and not how many
   --  nodes share the name, so a common utility name resolved through a
   --  declared dependency is still a meaningful edge.
   function Resolve_Ambiguous
     (Refs          : in out Ports.Byte_Source.Source'Class;
      Path_To_Nodes :        Path_Nodes.Map; Path_To_Namespace : Path_Sets.Map;
      Path_To_Deps  :        Path_Sets.Map; Opts : Options := Default_Options)
      return Edge_Vectors.Vector;

   --  The edges of both, ordered as Compute orders its own and, when Top is
   --  not 0, capped again over the combined set. The join of
   --  Resolve_Ambiguous's recovered edges: a caller treats the result as one
   --  graph, never two.
   function Merge_Edges
     (Edges, Extra : Edge_Vectors.Vector; Top : Natural)
      return Edge_Vectors.Vector;

   --  `from <TAB> to <TAB> weight <TAB> symbol symbol ...` and a line feed.
   function Image (E : Edge) return String;

end Synapse.Core.Links;
