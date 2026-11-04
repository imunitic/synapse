with Synapse.Pipeline.Registry_Store;

--  What every registry store must do, checked by calling it. The ids used are
--  Prefix & "-a" and Prefix & "-b", so a store that already holds other
--  executions is left as it was.

package Synapse.Pipeline.Registry_Contract is

   procedure Check
     (S      : in out Registry_Store.Store'Class;
      Prefix : String);

end Synapse.Pipeline.Registry_Contract;
