with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Results;
with Synapse.Pipeline.Resolved;

--  Which edge leaves a step once it has finished: the choice a run makes from
--  a step's result and from how often each edge has already fired. What a
--  guard is, and whether it holds of a result, is Guards'.

package Synapse.Pipeline.Routing is

   package JSON renames Synapse.Core.JSON;

   --  How many times each edge has fired so far, in the order of the
   --  pipeline's edges; an edge past the end has fired none.
   package Count_Vectors is new Ada.Containers.Vectors (Positive, Natural);

   --  The edge that fires, if one does.
   type Route (Fires : Boolean := False) is record
      case Fires is
         when True =>
            --  An index into the pipeline's edges.
            Edge : Positive;

         when False =>
            null;
      end case;
   end record;

   package Route_Results is new Synapse.Core.Results
     (Route, Ada.Strings.Unbounded.Unbounded_String);

   --  The first of the edges leaving Step whose guard holds of Result. An
   --  edge without a guard always holds. An edge that has fired its
   --  `Max_Iterations` times is passed over without its guard being looked
   --  at. When no edge fires, execution goes on to the next declared step,
   --  which is for the caller to say. A guard that fails fails the routing,
   --  naming the edge.
   function Route_After
     (Edges  : Resolved.Edge_Vectors.Vector;
      Fired  : Count_Vectors.Vector;
      Step   : String;
      Result : JSON.Value) return Route_Results.Result;

end Synapse.Pipeline.Routing;
