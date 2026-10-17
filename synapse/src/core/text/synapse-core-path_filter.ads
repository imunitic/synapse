with Synapse.Core.JSON;

--  Scoping a set of nodes by a JsonLogic rule over their paths.

package Synapse.Core.Path_Filter is

   --  Whether the rule, evaluated against `{"path": Name}` with the built-in
   --  operators, is truthy. A rule that raises a JsonLogic exception does not
   --  match: a node that cannot be judged is out.
   function Matches (Filter : JSON.Value; Name : String) return Boolean;

end Synapse.Core.Path_Filter;
