with Ada.Strings.Unbounded;

with Synapse.Core.Grammar_Registry;
with Synapse.Core.Kind_Synonyms;
with Synapse.Ports.Extractor_Factory;

--  What a command that tags files reads from the configuration before it asks
--  for an extractor: the grammar registry, the directory the grammars are
--  built in, the kind synonym rules, how long to wait for a grammar's lock
--  and where a person's own queries are.
package Synapse.Commands.Tagging_Support is

   type Load_Status is (Loaded, No_Home, Unreadable);

   --  `synapse-grammars.conf`, found through the configuration tiers and else
   --  in `~/.claude`. A missing file is an empty registry. Path is where it
   --  was looked for.
   procedure Load_Registry
     (Env    :     Environment; Registry : out Core.Grammar_Registry.Registry;
      Path   : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Load_Status);

   --  `synapse-kind-synonyms.conf`, which `SYNAPSE_KIND_SYNONYMS_CONF` can
   --  name. A missing file is no rules.
   procedure Load_Rules
     (Env    :     Environment; Rules : out Core.Kind_Synonyms.Rule_List;
      Path   : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Load_Status);

   --  The directory grammars are cloned and built in:
   --  `SYNAPSE_GRAMMARS_DIR`, else the home's cache. Not found without a
   --  home when nothing names one.
   procedure Grammars_Dir
     (Env   : Environment; Dir : out Ada.Strings.Unbounded.Unbounded_String;
      Found : out Boolean);

   --  The settings of an extractor from the registry and the rules: the
   --  grammars directory is Dir, the lock tries and the query directory come
   --  from the configuration.
   function Settings_For
     (Env : Environment; Registry : Core.Grammar_Registry.Registry;
      Dir : String; Rules : Core.Kind_Synonyms.Rule_List)
      return Synapse.Ports.Extractor_Factory.Settings;

end Synapse.Commands.Tagging_Support;
