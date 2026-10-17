with Ada.Strings.Unbounded;

with Synapse.Core.JSON_Logic;

package body Synapse.Core.Path_Filter is

   function Matches (Filter : JSON.Value; Name : String) return Boolean is
      Data : constant JSON.Value :=
        JSON.Make_Object
          ([JSON.Member'
              (Key  => Ada.Strings.Unbounded.To_Unbounded_String ("path"),
               Item => JSON.Make_String (Name))]);
   begin
      return
        JSON_Logic.Truthy
          (JSON_Logic.Evaluate (Filter, (Data => Data, others => <>)));
   exception
      when JSON_Logic.Unknown_Operator
         | JSON_Logic.Invalid_Arguments
         | JSON_Logic.Pattern_Too_Complex =>
         return False;
   end Matches;

end Synapse.Core.Path_Filter;
