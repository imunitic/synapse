with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Finalization;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Tree_Sitter.Preparation;
with Synapse.Adapters.Tree_Sitter.Tagger;
with Synapse.Core.Grammar_Registry;
with Synapse.Core.Kind_Synonyms;
with Synapse.Core.Text_Lists;
with Synapse.Ports.Extractor;
with Synapse.Ports.Library_Loader;
with Synapse.Ports.Process_Runner;

--  The extractor the application wires: registry in, tags out. For each
--  extension it resolves the registry entry, clones, builds and loads the
--  grammar and builds a tagger from the query the entry names, once. An
--  extension that cannot be used is reported once and then skipped without
--  being resolved again.
--
--  The query comes from the first of these that exists: a file the person
--  wrote for the extension in the override directory (`<ext>.scm`), a query
--  written from the grammar's `node-types.json` when the registry says so, and
--  otherwise the repository's own `queries/tags.scm` or `queries/locals.scm`.
--  Beside any of them, a `locals.scm` (the override directory's
--  `<ext>.locals.scm` first) filters references bound in the same file.

package Synapse.Adapters.Tree_Sitter.Extractor with
  SPARK_Mode => Off
is

   package Port renames Synapse.Ports.Extractor;

   --  Where a message for a person goes. The default writes a line to
   --  standard error.
   type Reporter is access procedure (Message : String);

   procedure Report_To_Standard_Error (Message : String);

   type Tagging_Extractor
     (Run    : not null access Synapse.Ports.Process_Runner.Runner'Class;
      Loader : not null access Synapse.Ports.Library_Loader.Loader'Class)
   is
     limited new Ada.Finalization.Limited_Controlled and
       Port.Locating_Extractor with private;

   --  Override_Dir is the directory of per-extension query files.
   procedure Configure
     (E : in out Tagging_Extractor; Registry : Core.Grammar_Registry.Registry;
      Grammars_Dir :        String; Rules : Core.Kind_Synonyms.Rule_List;
      Max_Tries    :        Positive := Preparation.Default_Lock_Tries;
      Override_Dir :    Core.Grammar_Registry.Maybe_Text := (Found => False);
      Report       :        Reporter := Report_To_Standard_Error'Access);

   --  How many extensions have been resolved, the unusable ones included.
   function Resolved_Extensions (E : Tagging_Extractor) return Natural;

   overriding function Extract
     (E     : in out Tagging_Extractor; Root : String;
      Paths :    Core.Text_Lists.Vector) return Port.Outcome_Vectors.Vector;

   overriding function Extract_Located
     (E     : in out Tagging_Extractor; Root : String;
      Paths :        Core.Text_Lists.Vector)
      return Port.Located_Outcome_Vectors.Vector;

   overriding procedure Finalize (E : in out Tagging_Extractor);

private

   type Tagger_Access is access Tagger.Tagger;

   package Caches is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Tagger_Access, Ada.Strings.Hash, "=");

   type Tagging_Extractor
     (Run    : not null access Synapse.Ports.Process_Runner.Runner'Class;
      Loader : not null access Synapse.Ports.Library_Loader.Loader'Class)
   is
   limited new Ada.Finalization.Limited_Controlled and
     Port.Locating_Extractor with record
      Registry     : Core.Grammar_Registry.Registry;
      Grammars_Dir : Ada.Strings.Unbounded.Unbounded_String;
      Rules        : Core.Kind_Synonyms.Rule_List;
      Max_Tries    : Positive := Preparation.Default_Lock_Tries;
      Override_Dir : Core.Grammar_Registry.Maybe_Text;
      Report       : Reporter := Report_To_Standard_Error'Access;
      --  A null tagger means the extension is known to be unusable.
      Taggers      : Caches.Map;
   end record;

end Synapse.Adapters.Tree_Sitter.Extractor;
