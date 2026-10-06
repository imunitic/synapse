with Ada.Environment_Variables;
with Ada.Strings.Unbounded;

package body Synapse.Adapters.System_Variables is

   function Lookup (Name : String) return Port.Maybe_Value
   is (if Ada.Environment_Variables.Exists (Name)
       then (Found => True,
             Text  => Ada.Strings.Unbounded.To_Unbounded_String
                        (Ada.Environment_Variables.Value (Name)))
       else (Found => False));

   overriding
   function Get (V : System_Variables; Name : String) return Port.Maybe_Value
   is
      pragma Unreferenced (V);
      Direct : constant Port.Maybe_Value := Lookup (Name);
   begin
      if Direct.Found or else Name /= "HOME" then
         return Direct;
      end if;
      return Lookup ("USERPROFILE");
   end Get;

end Synapse.Adapters.System_Variables;
