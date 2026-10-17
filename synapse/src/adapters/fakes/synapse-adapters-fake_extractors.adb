package body Synapse.Adapters.Fake_Extractors is

   overriding function Locating
     (F : in out Fake_Factory; S : Synapse.Ports.Extractor_Factory.Settings)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class
   is
      pragma Unreferenced (S);
   begin
      return F.Source'Unchecked_Access;
   end Locating;

   overriding function Find_Pairs
     (F : in out Fake_Factory; S : Synapse.Ports.Extractor_Factory.Settings;
      Extension, Source : String) return Synapse.Ports.Docstring_Pairs.Finding
   is
      pragma Unreferenced (S, Extension);
   begin
      F.Asked := F.Asked + 1;
      return
        (if F.Pairs.Contains (Source) then F.Pairs (Source)
         else (Kind => Synapse.Ports.Docstring_Pairs.No_Grammar));
   end Find_Pairs;

   overriding function Worker
     (F : in out Fake_Factory; S : Synapse.Ports.Extractor_Factory.Settings;
      Index :        Positive)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class
   is
      pragma Unreferenced (Index);
   begin
      return Locating (F, S);
   end Worker;

end Synapse.Adapters.Fake_Extractors;
