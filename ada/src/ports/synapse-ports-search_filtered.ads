with Synapse.Core.JSON;
with Synapse.Ports.Store;

--  Full-text search scoped to the nodes whose paths pass a filter. A separate
--  capability from Store: a store opts into it, as it may opt into others.

package Synapse.Ports.Search_Filtered is

   --  Either no filter, or a JsonLogic rule that mentions only `path`.
   type Path_Filter (Present : Boolean := False) is record
      case Present is
         when True =>
            Rule : Core.JSON.Value;

         when False =>
            null;
      end case;
   end record;

   No_Filter : constant Path_Filter := (Present => False);

   type Searchable is limited interface;

   --  The nodes that pass Filter, ranked for Query. With no filter this is
   --  Store.Search.
   function Search_Filtered
     (S      : in out Searchable;
      Query  : String;
      Filter : Path_Filter) return Store.Hit_Vectors.Vector
   is abstract;

end Synapse.Ports.Search_Filtered;
