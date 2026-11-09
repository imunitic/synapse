with Ada.Strings.Unbounded;

with Synapse.Adapters.Conf_Files;

package body Synapse.Adapters.Work_Dirs is

   use Ada.Strings.Unbounded;

   function Root (V : Variables) return String is
      Named : constant Synapse.Adapters.Conf_Files.Maybe_Path :=
        Synapse.Adapters.Conf_Files.Resolve (V, Setting);
   begin
      if Named.Found and then Length (Named.Value) > 0 then
         return To_String (Named.Value);
      end if;
      declare
         Home : constant Synapse.Ports.Variables.Maybe_Value := V.Get ("HOME");
      begin
         if Home.Found and then Length (Home.Value) > 0 then
            return To_String (Home.Value) & "/" & Default_Under_Home;
         end if;
      end;
      return "";
   end Root;

   function Of_Namespace (V : Variables; Namespace : String) return String is
      Where : constant String := Root (V);
   begin
      return (if Where = "" then "" else Where & "/" & Namespace);
   end Of_Namespace;

end Synapse.Adapters.Work_Dirs;
