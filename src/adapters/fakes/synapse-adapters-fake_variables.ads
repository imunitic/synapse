with Ada.Containers.Indefinite_Ordered_Maps;

with Synapse.Ports.Variables;

--  A table of variables, for tests.

package Synapse.Adapters.Fake_Variables is

   package Port renames Synapse.Ports.Variables;

   package Maps is new Ada.Containers.Indefinite_Ordered_Maps (String, String);

   type Fake_Variables is limited new Port.Variables with record
      Table : Maps.Map;
   end record;

   overriding
   function Get (V : Fake_Variables; Name : String) return Port.Maybe_Value;

   procedure Set (V : in out Fake_Variables; Name, Value : String);

end Synapse.Adapters.Fake_Variables;
