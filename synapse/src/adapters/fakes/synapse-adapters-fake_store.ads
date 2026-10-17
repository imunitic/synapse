with Ada.Containers.Indefinite_Ordered_Maps;

with Synapse.Core.Text_Lists;
with Synapse.Ports.Store;

--  A Store held entirely in memory, for tests of everything that uses one.

package Synapse.Adapters.Fake_Store is

   package Port renames Synapse.Ports.Store;

   package Node_Maps is new
     Ada.Containers.Indefinite_Ordered_Maps (String, String);

   type Fake_Store is limited new Port.Store with record
      Nodes : Node_Maps.Map;
      Reads, Writes, Lists : Natural := 0;

      --  When set, the next call raises Store_Failure and clears it.
      Fail_Next : Boolean := False;
   end record;

   overriding
   function Read (S : in out Fake_Store; Node : String) return Port.Maybe_Text;

   overriding
   function Write
     (S : in out Fake_Store; Node, Content : String) return Port.Write_Result;

   overriding
   function List (S : in out Fake_Store) return Core.Text_Lists.Vector;

   --  Case-sensitive substring matching with score 1.0 and the whole text as
   --  context: no ranking, since an answer real adapters need not agree on
   --  would be asserted.
   overriding
   function Search
     (S : in out Fake_Store; Query : String) return Port.Hit_Vectors.Vector;

end Synapse.Adapters.Fake_Store;
