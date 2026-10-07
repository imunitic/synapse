with Synapse.Adapters.Tree_Sitter.Grammar;
with Synapse.Adapters.Tree_Sitter.Preparation;

package body Synapse.Adapters.Tree_Sitter.Resolution is

   package Registry_Types renames Synapse.Core.Grammar_Registry;
   package Prep renames Synapse.Adapters.Tree_Sitter.Preparation;

   use type Registry_Types.Readiness_Kind;

   function Resolve
     (Run       : in out Synapse.Ports.Process_Runner.Runner'Class;
      Loader    : in out Synapse.Ports.Library_Loader.Loader'Class;
      Registry  :        Registry_Types.Registry; Grammars_Dir : String;
      Extension :        String; Max_Tries : Positive) return Resolution
   is
      Ready : constant Registry_Types.Readiness  :=
        Registry_Types.Lookup (Registry, Extension);
      Repo  : constant Registry_Types.Maybe_Text :=
        Registry_Types.Repo_For (Registry, Extension);
   begin
      case Ready.Kind is
         when Registry_Types.No_Entry =>
            return (Which => Not_Registered);

         when Registry_Types.Unusable =>
            return (Which => Not_Usable);

         when Registry_Types.Ready =>
            null;
      end case;
      if not Repo.Present then
         return (Which => Not_Usable);
      end if;

      declare
         Url    : constant String            := To_String (Repo.Text);
         Cloned : constant Prep.Clone_Result :=
           Prep.Ensure_Cloned (Run, Url, Grammars_Dir & "/repos", Max_Tries);
      begin
         if not Cloned.Ok then
            return
              (Which  => Failed,
               Detail => To_Unbounded_String (Prep.Describe (Cloned.Why)));
         end if;
         declare
            Loaded : constant Prep.Resolved :=
              Prep.Resolve_And_Load
                (Run, Loader, To_String (Cloned.Dir), Grammars_Dir,
                 Registry_Types.Repo_Name_Of (Url),
                 Registry_Types.Path_For (Registry, Extension),
                 Registry_Types.Symbol_For (Registry, Extension), Max_Tries);
         begin
            case Loaded.Kind is
               when Prep.Loaded =>
                  return
                    (Which    => Resolved, Lang => Loaded.Item,
                     Repo_Dir => Cloned.Dir, Scope => Ready.Scope,
                     Source   => Ready.Source);

               when Prep.Not_Prepared =>
                  return
                    (Which  => Failed,
                     Detail =>
                       To_Unbounded_String (Prep.Describe (Loaded.Why)));

               when Prep.Not_Loadable =>
                  return
                    (Which  => Failed,
                     Detail =>
                       To_Unbounded_String
                         ("the grammar could not be loaded: " &
                          Grammar.Load_Error'Image (Loaded.Error)));
            end case;
         end;
      end;
   end Resolve;

end Synapse.Adapters.Tree_Sitter.Resolution;
