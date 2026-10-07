--  The value of a success that has nothing to report: what `Results` carries
--  for an operation that either worked or says why not.
package Synapse.Core.Unit is

   type Unit is null record;

   Nothing : constant Unit := (null record);

end Synapse.Core.Unit;
