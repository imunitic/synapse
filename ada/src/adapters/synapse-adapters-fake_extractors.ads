with Synapse.Adapters.Fake_Extractor;
with Synapse.Ports.Extractor;
with Synapse.Ports.Extractor_Factory;

--  An extractor factory that hands out one scripted extractor, whatever the
--  settings, for a test of a command that tags.
package Synapse.Adapters.Fake_Extractors is

   type Fake_Factory is
   limited new Synapse.Ports.Extractor_Factory.Factory with record
      Source : aliased Synapse.Adapters.Fake_Extractor.Fake;
   end record;

   overriding function Locating
     (F : in out Fake_Factory; S : Synapse.Ports.Extractor_Factory.Settings)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class;

   --  The one scripted extractor for every index; it serializes its calls.
   overriding function Worker
     (F : in out Fake_Factory; S : Synapse.Ports.Extractor_Factory.Settings;
      Index :        Positive)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class;

end Synapse.Adapters.Fake_Extractors;
