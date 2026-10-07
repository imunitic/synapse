with Ada.Strings.Unbounded;

package body Synapse.Adapters.System_Extractors is

   overriding function Locating
     (F : in out System_Extractors;
      S :        Synapse.Ports.Extractor_Factory.Settings)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class
   is
   begin
      Tree_Sitter.Extractor.Configure
        (F.Tagging, S.Registry,
         Ada.Strings.Unbounded.To_String (S.Grammars_Dir), S.Rules,
         S.Max_Tries, S.Override_Dir);
      return F.Tagging'Unchecked_Access;
   end Locating;

end Synapse.Adapters.System_Extractors;
