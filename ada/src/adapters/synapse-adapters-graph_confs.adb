with Ada.Strings.Unbounded;

with Synapse.Adapters.File_Bytes;

package body Synapse.Adapters.Graph_Confs is

   Largest_Conf : constant := 8 * 1_024 * 1_024;

   --  The text of a configuration file, "[]" or "{}" when there is none.
   function Text_Of
     (V : Conf_Files.Variables; Name, Absent : String) return String
   is
      Found : constant Conf_Files.Maybe_Path :=
        Conf_Files.Resolve_Conf_Path (V, Name);
   begin
      if not Found.Found then
         return Absent;
      end if;
      return
        File_Bytes.Read
          (Ada.Strings.Unbounded.To_String (Found.Path), Largest_Conf);
   end Text_Of;

   function Load_Kind_Synonyms
     (V : Conf_Files.Variables) return Core.Kind_Synonyms.Rule_List is
     (Core.Kind_Synonyms.Parse (Text_Of (V, Kind_Synonyms_Conf, "[]")));

   function Load_Fence_Languages
     (V : Conf_Files.Variables) return Core.Fence_Languages.Registry is
     (Core.Fence_Languages.Parse (Text_Of (V, Fence_Languages_Conf, "{}")));

   function Load_Namespace_Rules
     (V : Conf_Files.Variables) return Core.Namespace.Registry is
     (Core.Namespace.Parse (Text_Of (V, Namespace_Rules_Conf, "{}")));

   function Load_Dependency_Rules
     (V : Conf_Files.Variables) return Core.Namespace.Registry is
     (Core.Namespace.Parse (Text_Of (V, Dependency_Rules_Conf, "{}")));

   function Load_Grammar_Registry
     (V : Conf_Files.Variables) return Core.Grammar_Registry.Registry is
     (Core.Grammar_Registry.Parse (Text_Of (V, Grammars_Conf, "{}")));

end Synapse.Adapters.Graph_Confs;
