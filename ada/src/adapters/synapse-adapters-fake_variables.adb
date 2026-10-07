with Ada.Strings.Unbounded;

package body Synapse.Adapters.Fake_Variables is

   overriding function Get
     (V : Fake_Variables; Name : String) return Port.Maybe_Value is
     (if V.Table.Contains (Name) then
        (Found => True,
         Value =>
           Ada.Strings.Unbounded.To_Unbounded_String (V.Table.Element (Name)))
      else (Found => False));

   procedure Set (V : in out Fake_Variables; Name, Value : String) is
   begin
      V.Table.Include (Name, Value);
   end Set;

end Synapse.Adapters.Fake_Variables;
