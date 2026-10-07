package body Synapse.Adapters.Fake_Extractors is

   overriding function Locating
     (F : in out Fake_Factory; S : Synapse.Ports.Extractor_Factory.Settings)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class
   is
      pragma Unreferenced (S);
   begin
      return F.Source'Unchecked_Access;
   end Locating;

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
