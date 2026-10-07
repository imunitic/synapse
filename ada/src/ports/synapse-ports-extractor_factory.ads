with Ada.Strings.Unbounded;

with Synapse.Core.Grammar_Registry;
with Synapse.Core.Kind_Synonyms;
with Synapse.Ports.Extractor;

--  Where a command gets the extractor it tags with. A command reads the
--  grammar registry, the directories and the rules from the configuration
--  and then asks for an extractor that uses them, so the program decides
--  what that extractor is: the real one over tree-sitter grammars, or a
--  scripted one for a test.
package Synapse.Ports.Extractor_Factory is

   type Settings is record
      Registry     : Core.Grammar_Registry.Registry;
      Grammars_Dir : Ada.Strings.Unbounded.Unbounded_String;
      Rules        : Core.Kind_Synonyms.Rule_List;
      --  How many times a grammar's lock is tried before giving up.
      Max_Tries    : Positive := 300;
      --  A directory of queries of a person's own, which win over the
      --  grammar's.
      Override_Dir : Core.Grammar_Registry.Maybe_Text;
   end record;

   type Factory is limited interface;

   --  The extractor configured with S. It belongs to the factory and stays
   --  valid until the factory is asked again or finishes.
   function Locating
     (F : in out Factory; S : Settings)
      return not null access Extractor.Locating_Extractor'Class is abstract;

   --  An extractor for one of several tasks tagging at once: Index names
   --  it, and two indexes never share state. Like Locating's it belongs to
   --  the factory. Called before the tasks start, never from them.
   function Worker
     (F : in out Factory; S : Settings; Index : Positive)
      return not null access Extractor.Locating_Extractor'Class is abstract;

end Synapse.Ports.Extractor_Factory;
