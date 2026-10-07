with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Synapse.Adapters.Tree_Sitter.Docstring_Pairs;
with Synapse.Adapters.Tree_Sitter.Resolution;

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

   overriding function Find_Pairs
     (F : in out System_Extractors;
      S : Synapse.Ports.Extractor_Factory.Settings; Extension, Source : String)
      return Synapse.Ports.Docstring_Pairs.Finding
   is
      package Resolve renames Tree_Sitter.Resolution;
      package Pairs renames Tree_Sitter.Docstring_Pairs;

      Resolved : constant Resolve.Resolution :=
        Resolve.Resolve
          (F.Run.all, F.Loader.all, S.Registry,
           Ada.Strings.Unbounded.To_String (S.Grammars_Dir), Extension,
           S.Max_Tries);
   begin
      if Resolved.Which in
          Resolve.Not_Registered | Resolve.Not_Usable | Resolve.Failed
      then
         return (Kind => Synapse.Ports.Docstring_Pairs.No_Grammar);
      end if;
      declare
         Found : constant Pairs.Pair_Results.Result :=
           Pairs.Find_Pairs
             (Resolved.Lang, Source,
              Pairs.Comment_Type_Name (S.Override_Dir, Extension),
              Pairs.Declaration_Overrides (S.Override_Dir, Extension));
      begin
         if not Pairs.Pair_Results.Is_Success (Found) then
            return (Kind => Synapse.Ports.Docstring_Pairs.Failed);
         end if;
         return
           (Kind  => Synapse.Ports.Docstring_Pairs.Found,
            Pairs => Pairs.Pair_Results.Value (Found));
      end;
   end Find_Pairs;

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
