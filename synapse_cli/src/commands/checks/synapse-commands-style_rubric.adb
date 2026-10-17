with Ada.Strings.Unbounded;

with Synapse.Adapters.Conf_Files;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Comment_Style_Rules;

package body Synapse.Commands.Style_Rubric is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;

   Largest_Rubric : constant := 1_024 * 1_024;

   function Text (Env : Environment) return String is
      Where : constant Support.Maybe_Path :=
        Adapters.Conf_Files.Resolve_Conf_Path
          (Env.Vars.all, Core.Comment_Style_Rules.Conf_Name);
      Text  : Unbounded_String;
      Found : Boolean;
   begin
      if not Where.Found then
         return "";
      end if;
      Support.Read_File (To_String (Where.Value), Largest_Rubric, Text, Found);
      return (if Found then To_String (Text) else "");
   end Text;

end Synapse.Commands.Style_Rubric;
