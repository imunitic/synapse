with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.Docstring_Cache;
with Synapse.Commands.Graph_Support;
with Synapse.Commands.Tagging_Support;
with Synapse.Core.Comment_Style_Rules;
with Synapse.Core.Grammar_Registry;
with Synapse.Core.Hashing;
with Synapse.Core.Kind_Synonyms;
with Synapse.Ports.Docstring_Pairs;

package body Synapse.Commands.Docstring_Check is

   use Ada.Strings.Unbounded;

   package Cache_Adapter renames Synapse.Adapters.Docstring_Cache;
   package Pairs renames Synapse.Ports.Docstring_Pairs;
   package Support renames Synapse.Commands.Graph_Support;
   package Tagging renames Synapse.Commands.Tagging_Support;

   use type Cache_Adapter.Issue;
   use type Tagging.Load_Status;

   LF : constant Character := Character'Val (10);

   Largest_Source : constant := 256 * 1_024 * 1_024;

   Largest_Rubric : constant := 1_024 * 1_024;

   function Failed (Why : String) return Result is
     (Which => Failed, Why => To_Unbounded_String (Why), others => <>);

   --  The rubric file, or nothing.
   function Rubric (Env : Environment) return String is
      Where : constant Support.Maybe_Path :=
        Adapters.Conf_Files.Resolve_Conf_Path
          (Env.Vars.all, Core.Comment_Style_Rules.Conf_Name);
      Text  : Unbounded_String;
      Found : Boolean;
   begin
      if not Where.Found then
         return "";
      end if;
      Support.Read_File (To_String (Where.Value), Largest_Rubric, Text, Found);
      return (if Found then To_String (Text) else "");
   end Rubric;

   function Is_Same (Left, Right : Unbounded_String) return Boolean is
     (Left = Right);

   function Check_File
     (Env : Environment; Repo_Root, Work, Rel_Path : String) return Result
   is
      Extension : constant String :=
        Core.Grammar_Registry.Extension_Of (Rel_Path);
   begin
      if not Cache_Adapter.Enabled (Env.Vars.all) or else Extension = "" then
         return (others => <>);
      end if;

      declare
         Registry      : Core.Grammar_Registry.Registry;
         Registry_Path : Unbounded_String;
         Dir           : Unbounded_String;
         Have_Dir      : Boolean;
         Status        : Tagging.Load_Status;
      begin
         Tagging.Load_Registry (Env, Registry, Registry_Path, Status);
         if Status /= Tagging.Loaded then
            return Failed ("cannot read the grammar registry");
         end if;
         Tagging.Grammars_Dir (Env, Dir, Have_Dir);
         if not Have_Dir then
            return Failed ("no home to hold the grammars");
         end if;

         declare
            Source_Text : Unbounded_String;
            Read        : Boolean;
         begin
            Support.Read_File
              (Repo_Root & "/" & Rel_Path, Largest_Source, Source_Text, Read);
            if not Read then
               return (others => <>);
            end if;

            declare
               Found : constant Pairs.Finding :=
                 Env.Extractors.Find_Pairs
                   (Tagging.Settings_For
                      (Env, Registry, To_String (Dir),
                       Core.Kind_Synonyms.Rule_List'(others => <>)),
                    Extension, To_String (Source_Text));
            begin
               case Found.Kind is
                  when Pairs.No_Grammar =>
                     return (others => <>);

                  when Pairs.Failed =>
                     return Failed ("could not parse " & Rel_Path);

                  when Pairs.Found =>
                     null;
               end case;

               declare
                  Cache      : Cache_Adapter.Cache;
                  Updates    : Cache_Adapter.Update_Vectors.Vector;
                  Removals   : Cache_Adapter.Key_Vectors.Vector;
                  Findings   : Unbounded_String;
                  Result_Out : Result;
               begin
                  Cache_Adapter.Open (Cache, Work & "/_docstring_index.bin");
                  if Cache_Adapter.Discarded (Cache) = Cache_Adapter.Unreadable
                  then
                     return (others => <>);
                  end if;

                  --  Every pair becomes an update, whether or not its hash
                  --  changed: the next re-hash needs an accurate range even
                  --  for a pair whose content never moved.
                  for P of Found.Pairs loop
                     Updates.Append
                       (Cache_Adapter.Update'
                          (Where =>
                             (Path => To_Unbounded_String (Rel_Path),
                              Name => P.Name, Kind => P.Kind),
                           Which =>
                             (Docstring_Hash  =>
                                Core.Hashing.Sha256_Raw
                                  (To_String (P.Docstring_Text)),
                              Decl_Hash       =>
                                Core.Hashing.Sha256_Raw
                                  (To_String (P.Decl_Text)),
                              Docstring_Start => P.Docstring_Start_Line,
                              Docstring_End   => P.Docstring_End_Line,
                              Decl_Start      => P.Decl_Start_Line,
                              Decl_End        => P.Decl_End_Line)));
                  end loop;

                  declare
                     Changed  : constant Cache_Adapter.Update_Vectors.Vector :=
                       Cache_Adapter.Needs_Check (Cache, Updates);
                     Existing :
                       constant Cache_Adapter.File_Entry_Vectors.Vector :=
                       Cache_Adapter.Entries_For_Path (Cache, Rel_Path);
                  begin
                     --  What the index holds for this file and the parse no
                     --  longer finds: a declaration renamed, or its docstring
                     --  removed.
                     for E of Existing loop
                        declare
                           Present : Boolean := False;
                        begin
                           for P of Found.Pairs loop
                              if Is_Same (P.Name, E.Name)
                                and then Is_Same (P.Kind, E.Kind)
                              then
                                 Present := True;
                                 exit;
                              end if;
                           end loop;
                           if not Present then
                              Removals.Append
                                (Cache_Adapter.Key'
                                   (Path => To_Unbounded_String (Rel_Path),
                                    Name => E.Name, Kind => E.Kind));
                           end if;
                        end;
                     end loop;

                     Result_Out.Evicted :=
                       Cache_Adapter.Commit (Cache, Updates, Removals);
                     Result_Out.Which   := Checked;
                     Result_Out.Pairs   := Natural (Found.Pairs.Length);
                     Result_Out.Updated := Natural (Changed.Length);

                     for U of Changed loop
                        Append
                          (Findings,
                           "- `" & To_String (U.Where.Name) & "` (" &
                           To_String (U.Where.Kind) &
                           "): new or changed since last checked" & LF);
                        for P of Found.Pairs loop
                           if Is_Same (P.Name, U.Where.Name)
                             and then Is_Same (P.Kind, U.Where.Kind)
                           then
                              declare
                                 Phrase : constant String :=
                                   Core.Comment_Style_Rules
                                     .Historian_Plague_Phrase
                                     (To_String (P.Docstring_Text));
                              begin
                                 if Phrase /= "" then
                                    Append
                                      (Findings,
                                       "  historian-plague tell: """ & Phrase &
                                       """" & LF);
                                 end if;
                              end;
                              exit;
                           end if;
                        end loop;
                     end loop;
                  end;

                  if Length (Findings) /= 0 then
                     declare
                        Style : constant String := Rubric (Env);
                     begin
                        Result_Out.Report :=
                          To_Unbounded_String
                            ("Docstring staleness (Tier 2): the following " &
                             "changed since last checked:" & LF) &
                          Findings;
                        if Style /= "" then
                           Append
                             (Result_Out.Report,
                              LF & "Style rubric to judge the affected " &
                              "docstring(s) against:" & LF & Style);
                        end if;
                     end;
                  end if;
                  return Result_Out;
               exception
                  when Cache_Adapter.Unreadable_Cache =>
                     return (others => <>);
               end;
            end;
         end;
      end;
   end Check_File;

end Synapse.Commands.Docstring_Check;
