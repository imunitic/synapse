package body Synapse.Adapters.Null_Extractors is

   overriding function Locating
     (F : in out Null_Factory; S : Synapse.Ports.Extractor_Factory.Settings)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'
     Class is
     (raise Program_Error with "this program tags no files");

   overriding function Worker
     (F : in out Null_Factory; S : Synapse.Ports.Extractor_Factory.Settings;
      Index :        Positive)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'
     Class is
     (raise Program_Error with "this program tags no files");

   overriding function Find_Pairs
     (F : in out Null_Factory; S : Synapse.Ports.Extractor_Factory.Settings;
      Extension, Source :        String)
      return Synapse.Ports.Docstring_Pairs.Finding is
     (Kind => Synapse.Ports.Docstring_Pairs.No_Grammar);

end Synapse.Adapters.Null_Extractors;
