with Synapse.Ports.Docstring_Pairs;
with Synapse.Ports.Extractor;
with Synapse.Ports.Extractor_Factory;

--  The factory of a program that tags nothing: a hook reads what other
--  commands wrote and never parses a file, so it links no grammar. Asking for
--  an extractor is a fault in the program.
package Synapse.Adapters.Null_Extractors is

   type Null_Factory is
   limited new Synapse.Ports.Extractor_Factory.Factory with null record;

   overriding function Locating
     (F : in out Null_Factory; S : Synapse.Ports.Extractor_Factory.Settings)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class;

   overriding function Worker
     (F : in out Null_Factory; S : Synapse.Ports.Extractor_Factory.Settings;
      Index :        Positive)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class;

   overriding function Find_Pairs
     (F : in out Null_Factory; S : Synapse.Ports.Extractor_Factory.Settings;
      Extension, Source : String) return Synapse.Ports.Docstring_Pairs.Finding;

end Synapse.Adapters.Null_Extractors;
