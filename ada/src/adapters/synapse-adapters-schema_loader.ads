with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Ports.Variables;

--  Finding the schema a note declares, and the vocabulary files its rules
--  read.

package Synapse.Adapters.Schema_Loader is

   subtype Variables is Synapse.Ports.Variables.Variables'Class;

   type Load_Result (Ok : Boolean := False) is record
      case Ok is
         when True =>
            Schema : Core.JSON.Value;

         when False =>
            --  The name of what went wrong: `ContentRootMissing`,
            --  `FileNotFound`, or the name of a fault of the schema YAML
            --  reader or of the override merge (`EmptyDocument`,
            --  `PatchMatchNotFound`, ...).
            Fault  : Ada.Strings.Unbounded.Unbounded_String;
      end case;
   end record;

   --  `$SYNAPSE_CONTENT_ROOT/schema/{Schema_Id}.yaml`, parsed, with the
   --  override at `schema-overrides/{Schema_Id}.yaml` (found through the
   --  configuration tiers) merged over it when there is one. The override
   --  absent leaves the schema exactly as shipped.
   function Load_Schema (V : Variables; Schema_Id : String) return Load_Result;

   type Maybe_Text (Found : Boolean := False) is record
      case Found is
         when True =>
            Text : Ada.Strings.Unbounded.Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  The text of the configuration file Name (`synapse-tag-vocabulary.conf`),
   --  found through the configuration tiers. Nothing when there is none, and
   --  nothing, with a note on standard error, when it cannot be read.
   function Load_Vocabulary (V : Variables; Name : String) return Maybe_Text;

   --  Whether Id is `kind/version` shaped and cannot name a file elsewhere: at
   --  least two `/`-separated segments, each of letters, digits, `-` and `_`.
   function Is_Safe_Schema_Id (Id : String) return Boolean;

end Synapse.Adapters.Schema_Loader;
