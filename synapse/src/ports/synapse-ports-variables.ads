with Synapse.Core.Optional_Text;

--  Where the value of a variable comes from: the process environment in
--  production, a table in tests. Passed in, never reached for, so reading
--  configuration is testable without touching the real environment.

package Synapse.Ports.Variables is

   subtype Maybe_Value is Synapse.Core.Optional_Text.Option;

   type Variables is limited interface;

   --  Nothing when the variable is not set. A variable set to the empty
   --  string is found.
   function Get (V : Variables; Name : String) return Maybe_Value is abstract;

   --  A variables source that knows nothing.
   type No_Variables is limited new Variables with null record;

   overriding
   function Get (V : No_Variables; Name : String) return Maybe_Value
   is ((Found => False));

end Synapse.Ports.Variables;
