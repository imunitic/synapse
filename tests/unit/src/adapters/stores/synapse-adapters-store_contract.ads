with Synapse.Ports.Store;

--  Behavior every Store must have, checked through the interface.

package Synapse.Adapters.Store_Contract is

   procedure Check (S : in out Synapse.Ports.Store.Store'Class);

end Synapse.Adapters.Store_Contract;
