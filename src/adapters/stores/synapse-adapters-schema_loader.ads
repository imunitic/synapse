with Ada.Strings.Unbounded;

with Synapse.Core.Results;
with Synapse.Core.Optional_Text;
with Synapse.Core.JSON;
with Synapse.Ports.Variables;

--  Finding the schema a note declares, and the vocabulary files its rules
--  read.

package Synapse.Adapters.Schema_Loader is

   subtype Variables is Synapse.Ports.Variables.Variables'Class;

   package Load_Results is new Synapse.Core.Results
     (Core.JSON.Value, Ada.Strings.Unbounded.Unbounded_String);

   subtype Load_Result is Load_Results.Result;

   --  `$SYNAPSE_CONTENT_ROOT/schema/{Schema_Id}.yaml`, parsed, with the
   --  override at `schema-overrides/{Schema_Id}.yaml` (found through the
   --  configuration tiers) merged over it when there is one. The override
   --  absent leaves the schema exactly as shipped.
   function Load_Schema (V : Variables; Schema_Id : String) return Load_Result;

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   --  The text of the configuration file Name (`synapse-tag-vocabulary.conf`),
   --  found through the configuration tiers. Nothing when there is none, and
   --  nothing, with a note on standard error, when it cannot be read.
   function Load_Vocabulary (V : Variables; Name : String) return Maybe_Text;

   --  Whether Id is `kind/version` shaped and cannot name a file elsewhere: at
   --  least two `/`-separated segments, each of letters, digits, `-` and `_`.
   function Is_Safe_Schema_Id (Id : String) return Boolean;

end Synapse.Adapters.Schema_Loader;
