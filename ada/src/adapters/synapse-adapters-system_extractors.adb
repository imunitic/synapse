with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

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

   overriding function Worker
     (F : in out System_Extractors;
      S :        Synapse.Ports.Extractor_Factory.Settings; Index : Positive)
      return not null access Synapse.Ports.Extractor.Locating_Extractor'Class
   is
   begin
      while Natural (F.Workers.Length) < Index loop
         F.Workers.Append
           (new Tree_Sitter.Extractor.Tagging_Extractor
              (F.Run.all'Unchecked_Access, F.Loader.all'Unchecked_Access));
      end loop;
      declare
         Own : constant Tagging_Access := F.Workers (Index);
      begin
         Tree_Sitter.Extractor.Configure
           (Own.all, S.Registry,
            Ada.Strings.Unbounded.To_String (S.Grammars_Dir), S.Rules,
            S.Max_Tries, S.Override_Dir);
         return Own;
      end;
   end Worker;

   overriding procedure Finalize (F : in out System_Extractors) is
      procedure Free is new Ada.Unchecked_Deallocation
        (Tree_Sitter.Extractor.Tagging_Extractor, Tagging_Access);
   begin
      for Own of F.Workers loop
         Free (Own);
      end loop;
      F.Workers.Clear;
   end Finalize;

end Synapse.Adapters.System_Extractors;
