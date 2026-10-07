with Ada.Containers.Vectors;
with Ada.Finalization;

with Synapse.Adapters.Tree_Sitter.Extractor;
with Synapse.Ports.Extractor;
with Synapse.Ports.Extractor_Factory;
with Synapse.Ports.Library_Loader;
with Synapse.Ports.Process_Runner;

--  The extractor of the `synapse` program: tree-sitter grammars, prepared on
--  first use with the runner and loaded with the loader.
package Synapse.Adapters.System_Extractors is

   type System_Extractors
     (Run    : not null access Synapse.Ports.Process_Runner.Runner'Class;
      Loader : not null access Synapse.Ports.Library_Loader.Loader'Class)
   is
     limited new Ada.Finalization.Limited_Controlled and
       Synapse.Ports.Extractor_Factory.Factory with private;

   overriding function Locating
     (F : in out System_Extractors;
      S :        Synapse.Ports.Extractor_Factory.Settings)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class;

   --  A tagger of its own for each index, made the first time it is asked
   --  for and kept until the factory finishes.
   overriding function Worker
     (F : in out System_Extractors;
      S :        Synapse.Ports.Extractor_Factory.Settings; Index : Positive)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class;

   overriding procedure Finalize (F : in out System_Extractors);

private

   type Tagging_Access is
     access Synapse.Adapters.Tree_Sitter.Extractor.Tagging_Extractor;

   package Worker_Vectors is new Ada.Containers.Vectors
     (Positive, Tagging_Access);

   type System_Extractors
     (Run    : not null access Synapse.Ports.Process_Runner.Runner'Class;
      Loader : not null access Synapse.Ports.Library_Loader.Loader'Class)
   is
   limited new Ada.Finalization.Limited_Controlled and
     Synapse.Ports.Extractor_Factory.Factory with record
      Tagging : aliased Synapse.Adapters.Tree_Sitter.Extractor
        .Tagging_Extractor
        (Run, Loader);
      Workers : Worker_Vectors.Vector;
   end record;

end Synapse.Adapters.System_Extractors;
