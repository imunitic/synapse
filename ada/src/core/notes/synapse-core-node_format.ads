with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Graph_Model;
with Synapse.Core.Text_Lists;

--  The node format.
--
--    ---
--    title: "State machine"
--    node_type: synapse-node
--    project: widget-repo
--    sources:
--      - path: engine/src/state.ext
--        hash: f98dd5a829c27ab4161f252ee857ece38e294d35
--    sources_digest: "df91a067..."
--    stale: false
--    built_at: "2026-08-03 16:50"
--    ---
--
--    # State machine
--    <!-- synapse:generated:start -->
--
--    ## Summary
--    ...prose...
--
--    ## Crux
--    ```
--    ...lines sliced verbatim from a source file...
--    ```
--
--    ## Links
--    - uses [[Another node]]
--
--    ## Sources
--    - `engine` (19)
--    <!-- synapse:generated:end -->
--
--    ## Notes
--
--  The fence is the contract with the person: everything between the markers
--  is regenerated on every write, and everything after the closing marker
--  (`## Notes` in practice) is carried through untouched.

package Synapse.Core.Node_Format is

   use Ada.Strings.Unbounded;

   Generated_Start : constant String := "<!-- synapse:generated:start -->";
   Generated_End   : constant String := "<!-- synapse:generated:end -->";

   Repo_Root_Module : constant String := "(repo root)";

   --  How many nodes a namespace can have. Every reader of `lists/` goes
   --  through slugs `001` to this number, so one past it would be written and
   --  never read. Tied to the three digit width of the slugs.
   Max_Nodes : constant := 200;

   --  The grouping of the `## Sources` mirror and of `query sources
   --  --modules`.
   --
   --  A configured boilerplate chain (a run of directories that carries no
   --  subsystem information) cuts the path at the segment before it, searched
   --  as a whole segment sequence, in the order of Chains: the first match
   --  wins. A flat `<pkg>/src/<subsystem>/...` layout has no such chain, and
   --  there the segment after `src/` is the subsystem. Failing both, the
   --  first path component; failing that, `(repo root)`. An empty list still
   --  groups, just without collapsing scaffolding.
   function Module_Of
     (Path : String; Chains : Text_Lists.Vector) return String;

   type Module_Count is record
      Module : Unbounded_String;
      Count  : Natural;
   end record;

   package Module_Count_Vectors is new Ada.Containers.Vectors
     (Positive, Module_Count);

   --  SHA-256 over the `path:hash` lines of the sources, sorted bytewise and
   --  joined by line feeds with no trailing one: 64 lowercase digits. The
   --  digest of no sources is the digest of nothing, a defined value and not
   --  an empty field.
   function Sources_Digest
     (Sources : Graph_Model.Source_Vectors.Vector) return String with
     Post => Sources_Digest'Result'Length = 64;

   --  A node split into the part a writer owns and the part a person does.
   type Split_Result is record
      --  Through the `# Title` line and the start marker.
      Head   : Unbounded_String;
      --  From the end marker on (`## Notes` and after). Empty when the node
      --  has no end marker.
      Tail   : Unbounded_String;
      --  Both markers were found. A node without them is not an error: the
      --  writer replaces the whole body.
      Fenced : Boolean := False;
   end record;

   --  Where the generated region begins and ends, so a rewrite can replace
   --  it and keep everything else byte for byte. A start marker with no end
   --  marker counts as unfenced.
   function Split (Text : String) return Split_Result;

end Synapse.Core.Node_Format;
