with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Core.Results;
with Synapse.Pipeline.Resolved;

--  The guards on a pipeline's edges: what a guard may see, whether a guard is
--  a rule that can be evaluated, and which edge leaves a step once it has
--  finished.
--
--  A guard is a JsonLogic rule over the finished step's result and nothing
--  else: `outcome`, `summary` and `data`, whatever else the result document
--  holds. It must come to a boolean; any other answer, and any rule the
--  evaluator cannot run, is a failure to report and not an answer, so a guard
--  that is wrong never moves a pipeline.

package Synapse.Pipeline.Guards is

   package JSON renames Synapse.Core.JSON;

   --  The result of a step as a guard sees it.
   function View
     (Outcome, Summary : String; Data : JSON.Value) return JSON.Value;

   --  What is wrong with Guard as a rule, found without running it: it must
   --  be a single rule, and every rule in it must name an operator the
   --  evaluator has. Nothing when it looks fine.
   function Problem (Guard : JSON.Value)
      return Synapse.Core.Optional_Text.Option;

   package Guard_Results is new Synapse.Core.Results
     (Boolean, Ada.Strings.Unbounded.Unbounded_String);

   --  Whether Guard holds of Result, a document with `outcome`, `summary`
   --  and `data` members. Only those three are visible to the rule; a missing
   --  field reads as null.
   function Holds
     (Guard : JSON.Value; Result : JSON.Value) return Guard_Results.Result;

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

end Synapse.Pipeline.Guards;
