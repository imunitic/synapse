with Synapse.Core.Options;
with Synapse.Core.JSON;
with Synapse.Ports.Store;

--  Full-text search scoped to the nodes whose paths pass a filter. A separate
--  capability from Store: a store opts into it, as it may opt into others.

package Synapse.Ports.Search_Filtered is

   --  Either no filter, or a JsonLogic rule that mentions only `path`.
   package Filter_Options is new Core.Options (Core.JSON.Value);

   subtype Path_Filter is Filter_Options.Option;

   No_Filter : constant Path_Filter := Filter_Options.None;

   type Searchable is limited interface;

   --  The nodes that pass Filter, ranked for Query. With no filter this is
   --  Store.Search.
   function Search_Filtered
     (S      : in out Searchable;
      Query  : String;
      Filter : Path_Filter) return Store.Hit_Vectors.Vector
   is abstract;

end Synapse.Ports.Search_Filtered;
