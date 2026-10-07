with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;

with Synapse.Adapters.Fake_Extractor;
with Synapse.Ports.Docstring_Pairs;
with Synapse.Ports.Extractor;
with Synapse.Ports.Extractor_Factory;

--  An extractor factory that hands out one scripted extractor, whatever the
--  settings, for a test of a command that tags.
package Synapse.Adapters.Fake_Extractors is

   use type Synapse.Ports.Docstring_Pairs.Finding;

   package Finding_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Synapse.Ports.Docstring_Pairs.Finding, Ada.Strings.Hash, "=");

   type Fake_Factory is
   limited new Synapse.Ports.Extractor_Factory.Factory with record
      Source : aliased Synapse.Adapters.Fake_Extractor.Fake;
      --  What Find_Pairs answers, by the text of the file; No_Grammar for
      --  text with no entry.
      Pairs  : Finding_Maps.Map;
      --  How many times Find_Pairs was asked.
      Asked  : Natural := 0;
   end record;

   overriding function Find_Pairs
     (F : in out Fake_Factory; S : Synapse.Ports.Extractor_Factory.Settings;
      Extension, Source : String) return Synapse.Ports.Docstring_Pairs.Finding;

   overriding function Locating
     (F : in out Fake_Factory; S : Synapse.Ports.Extractor_Factory.Settings)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class;

   --  The one scripted extractor for every index; it serializes its calls.
   overriding function Worker
     (F : in out Fake_Factory; S : Synapse.Ports.Extractor_Factory.Settings;
      Index :        Positive)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class;

end Synapse.Adapters.Fake_Extractors;
