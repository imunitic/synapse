with Synapse.Adapters.Conf_Files;
with Synapse.Core.Fence_Languages;
with Synapse.Core.Kind_Synonyms;

--  The two configuration files of the code graph that map one thing onto
--  another, found through the configuration tiers. Both ship empty, and an
--  absent file is an empty list: what a repository's grammars call things is
--  written there after it is checked against that repository.

package Synapse.Adapters.Graph_Confs is

   Kind_Synonyms_Conf   : constant String := "synapse-kind-synonyms.conf";
   Fence_Languages_Conf : constant String := "synapse-fence-languages.conf";

   --  Core.Kind_Synonyms.Malformed when the file is not JSON.
   function Load_Kind_Synonyms
     (V : Conf_Files.Variables) return Core.Kind_Synonyms.Rule_List;

   --  Core.Fence_Languages.Malformed when the file is not JSON.
   function Load_Fence_Languages
     (V : Conf_Files.Variables) return Core.Fence_Languages.Registry;

end Synapse.Adapters.Graph_Confs;
