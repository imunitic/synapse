with Synapse.Ports.Variables;

--  The process environment. `HOME` falls back to `USERPROFILE`, so a lookup
--  relative to the home directory works on Windows too.

package Synapse.Adapters.System_Variables is

   package Port renames Synapse.Ports.Variables;

   type System_Variables is limited new Port.Variables with null record;

   overriding
   function Get (V : System_Variables; Name : String) return Port.Maybe_Value;

end Synapse.Adapters.System_Variables;
