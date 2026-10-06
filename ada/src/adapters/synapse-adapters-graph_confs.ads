with Synapse.Adapters.Conf_Files;
with Synapse.Core.Fence_Languages;
with Synapse.Core.Kind_Synonyms;
with Synapse.Core.Namespace;

--  The two configuration files of the code graph that map one thing onto
--  another, found through the configuration tiers. Both ship empty, and an
--  absent file is an empty list: what a repository's grammars call things is
--  written there after it is checked against that repository.

package Synapse.Adapters.Graph_Confs is

   Kind_Synonyms_Conf    : constant String := "synapse-kind-synonyms.conf";
   Fence_Languages_Conf  : constant String := "synapse-fence-languages.conf";
   Namespace_Rules_Conf  : constant String := "synapse-namespace-rules.conf";
   Dependency_Rules_Conf : constant String := "synapse-dependency-rules.conf";

   --  Core.Kind_Synonyms.Malformed when the file is not JSON.
   function Load_Kind_Synonyms
     (V : Conf_Files.Variables) return Core.Kind_Synonyms.Rule_List;

   --  Core.Fence_Languages.Malformed when the file is not JSON.
   function Load_Fence_Languages
     (V : Conf_Files.Variables) return Core.Fence_Languages.Registry;

   --  The rules that find the namespace a file declares, and what it depends
   --  on, keyed by extension. Core.Namespace.Malformed when the file is not
   --  JSON.
   function Load_Namespace_Rules
     (V : Conf_Files.Variables) return Core.Namespace.Registry;

   function Load_Dependency_Rules
     (V : Conf_Files.Variables) return Core.Namespace.Registry;

end Synapse.Adapters.Graph_Confs;
