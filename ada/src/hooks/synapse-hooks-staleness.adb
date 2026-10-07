with Ada.Calendar;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

with Synapse.Adapters.Docstring_Cache;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Index_Map;
with Synapse.Commands.Style_Rubric;
with Synapse.Commands.Vault_Support;
with Synapse.Core.Comment_Style_Rules;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Emit;
with Synapse.Core.Hashing;
with Synapse.Core.Line_Slice;
with Synapse.Core.Node_Query;
with Synapse.Core.Text_Lists;
with Synapse.Core.Verify;
with Synapse.Ports.Store;
with Synapse.Ports.Variables;

package body Synapse.Hooks.Staleness is

   use Ada.Strings.Unbounded;

   package Image renames Synapse.Core.Decimal_Image;
   package Docs renames Synapse.Adapters.Docstring_Cache;
   package Verify renames Synapse.Core.Verify;
   package Slicing renames Synapse.Core.Line_Slice;
   package Vault_Support renames Synapse.Commands.Vault_Support;
   package Port renames Synapse.Ports.Store;

   use type Docs.Issue;
   use type Adapters.Index_Map.Issue;
   use type Ada.Directories.File_Kind;
   use type Core.Hashing.Digest;

   LF : constant Character := Character'Val (10);

   --  U+2014, spelled in UTF-8 bytes.
   Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   Largest : constant := 256 * 1_024 * 1_024;

   Seen_File_Max_Age : constant Duration := 7.0 * 24.0 * 3_600.0;

   function Read_Or_None (Path : String) return Common.Maybe_Text is
   begin
      if not Ada.Directories.Exists (Path) then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value =>
           To_Unbounded_String (Adapters.File_Bytes.Read (Path, Largest)));
   exception
      when others =>
         return (Found => False);
   end Read_Or_None;

   function Lines_Of
     (Content : String; First, Last : Natural; Cut : out Boolean) return String
   is
      Bounds : constant Slicing.Maybe_Bounds :=
        Slicing.Bounds (Content, First, Last);
   begin
      Cut := Bounds.Found;
      return
        (if Bounds.Found then Content (Bounds.Value.From .. Bounds.Value.To)
         else "");
   end Lines_Of;

   function Hex_Of (Item : Core.Hashing.Digest) return String is
      Digits_Of : constant String := "0123456789abcdef";
      Result    : String (1 .. 64);
   begin
      for I in Item'Range loop
         Result (2 * I - 1) := Digits_Of (Digits_Of'First + Item (I) / 16);
         Result (2 * I)     := Digits_Of (Digits_Of'First + Item (I) mod 16);
      end loop;
      return Result;
   end Hex_Of;

   ---------------------------------------------------------------------------
   --  Tier 1 of docstring staleness
   ---------------------------------------------------------------------------

   --  Whether the content at the stored range no longer hashes to Want: checked
   --  at the range first, then wherever the same lines went, in case they only
   --  shifted. True only when neither finds a match.
   function Range_Changed
     (Content : String; First, Last : Natural; Want : Core.Hashing.Digest)
      return Boolean
   is
      Cut     : Boolean;
      Current : constant String := Lines_Of (Content, First, Last, Cut);
   begin
      if Cut and then Core.Hashing.Sha256_Raw (Current) = Want then
         return False;
      end if;
      if Last < First or else First = 0 then
         return True;
      end if;
      return
        not Verify.Find_Moved (Content, Last - First + 1, Hex_Of (Want)).Found;
   end Range_Changed;

   function Check_Docstrings
     (Env : Environment; Work, Rel, File : String) return Common.Maybe_Text
   is
      Cache : Docs.Cache;
   begin
      if not Docs.Enabled (Env.Vars.all) then
         return (Found => False);
      end if;
      Docs.Open (Cache, Work & "/_docstring_index.bin");
      --  An index that cannot be read is silence too.
      if Docs.Discarded (Cache) /= Docs.None then
         return (Found => False);
      end if;
      declare
         Entries  : constant Docs.File_Entry_Vectors.Vector :=
           Docs.Entries_For_Path (Cache, Rel);
         Source   : constant Common.Maybe_Text := Read_Or_None (File);
         Findings : Unbounded_String;
      begin
         if Entries.Is_Empty or else not Source.Found then
            return (Found => False);
         end if;
         declare
            Content : constant String := To_String (Source.Value);
         begin
            for E of Entries loop
               declare
                  Doc_Changed  : constant Boolean :=
                    Range_Changed
                      (Content, E.Which.Docstring_Start, E.Which.Docstring_End,
                       E.Which.Docstring_Hash);
                  Decl_Changed : constant Boolean :=
                    Range_Changed
                      (Content, E.Which.Decl_Start, E.Which.Decl_End,
                       E.Which.Decl_Hash);
               begin
                  if Doc_Changed or else Decl_Changed then
                     Append
                       (Findings,
                        "- `" & To_String (E.Name) & "` (" &
                        To_String (E.Kind) & "): " &
                        (if Doc_Changed and then Decl_Changed then
                           "the docstring and the declaration both"
                         elsif Doc_Changed then "the docstring"
                         else "the declaration") &
                        " changed since last checked" & LF);
                     declare
                        Cut     : Boolean;
                        Current : constant String :=
                          Lines_Of
                            (Content, E.Which.Docstring_Start,
                             E.Which.Docstring_End, Cut);
                     begin
                        if Cut then
                           declare
                              Phrase : constant String :=
                                Core.Comment_Style_Rules
                                  .Historian_Plague_Phrase
                                  (Current);
                           begin
                              if Phrase /= "" then
                                 Append
                                   (Findings,
                                    "  historian-plague tell: """ & Phrase &
                                    """" & LF);
                              end if;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end;
         if Length (Findings) = 0 then
            return (Found => False);
         end if;
         declare
            Rubric : constant String  := Commands.Style_Rubric.Text (Env);
            Text   : Unbounded_String :=
              To_Unbounded_String
                ("Docstring staleness: these declarations' docstrings or " &
                 "bodies changed since they were last checked:" & LF) &
              Findings;
         begin
            if Rubric /= "" then
               Append
                 (Text,
                  LF & "Style rubric to judge the affected docstring(s) " &
                  "against:" & LF & Rubric);
            end if;
            return (Found => True, Value => Text);
         end;
      end;
   exception
      when others =>
         return (Found => False);
   end Check_Docstrings;

   ---------------------------------------------------------------------------
   --  Cited evidence
   ---------------------------------------------------------------------------

   --  `first-last` with blanks and quotes around either number.
   procedure Parse_Range
     (Text : String; First, Last : out Natural; Ok : out Boolean)
   is
      Dash_At : constant Natural := Ada.Strings.Fixed.Index (Text, "-");

      function Number (Part : String) return Natural is
         Clean : Unbounded_String;
      begin
         for C of Part loop
            if C not in ' ' | ASCII.HT | '"' then
               Append (Clean, C);
            end if;
         end loop;
         return Natural'Value (To_String (Clean));
      end Number;
   begin
      Ok    := False;
      First := 0;
      Last  := 0;
      if Dash_At = 0 then
         return;
      end if;
      First := Number (Text (Text'First .. Dash_At - 1));
      Last  := Number (Text (Dash_At + 1 .. Text'Last));
      Ok    := First > 0 and then Last >= First;
   exception
      when Constraint_Error =>
         Ok := False;
   end Parse_Range;

   --  Cited evidence in the edited file that no longer matches what was
   --  recorded. Silent when it still matches, or when the node cites nothing
   --  from this file.
   procedure Check_Cited_Evidence
     (Node_Text, Node_File, Rel, Content :        String;
      Into                               : in out Unbounded_String)
   is
      Name       : constant String                     :=
        (if
           Node_File'Length > 3
           and then Node_File (Node_File'Last - 2 .. Node_File'Last) = ".md"
         then Node_File (Node_File'First .. Node_File'Last - 3)
         else Node_File);
      Crux_Path  : constant Core.Node_Query.Maybe_Text :=
        Core.Node_Query.Field (Node_Text, "crux_path");
      Crux_Lines : constant Core.Node_Query.Maybe_Text :=
        Core.Node_Query.Field (Node_Text, "crux_lines");
   begin
      if Crux_Path.Found and then To_String (Crux_Path.Value) = Rel
        and then Crux_Lines.Found
      then
         declare
            First, Last : Natural;
            Ok          : Boolean;
         begin
            Parse_Range (To_String (Crux_Lines.Value), First, Last, Ok);
            if Ok then
               --  No digest is stored for the crux: the note's own fenced copy
               --  is the stored side.
               declare
                  Stored : constant String :=
                    Core.Emit.Fenced_Text (Node_Text);
                  Cut    : Boolean;
                  Actual : constant String :=
                    Lines_Of (Content, First, Last, Cut);
               begin
                  if Core.Hashing.Sha256_Hex (Stored) /=
                    Core.Hashing.Sha256_Hex (Actual)
                  then
                     Append
                       (Into,
                        "  - " & Name & " " & Dash & " crux (" & Rel & ":" &
                        To_String (Crux_Lines.Value) & ")" & LF);
                  end if;
               end;
            end if;
         end;
      end if;

      for G of Verify.Groundings (Node_Text) loop
         if To_String (G.Path) = Rel then
            declare
               Range_Of : constant Verify.Maybe_Range := Verify.Range_Of (G);
            begin
               if Range_Of.Found then
                  declare
                     Cut    : Boolean;
                     Actual : constant String :=
                       Lines_Of
                         (Content, Range_Of.Value.First, Range_Of.Value.Last,
                          Cut);
                  begin
                     if Core.Hashing.Sha256_Hex (Actual) /=
                       To_String (G.Digest)
                     then
                        Append
                          (Into,
                           "  - " & Name & " " & Dash & " grounding (" & Rel &
                           ":" & To_String (G.Lines) & ")" & LF);
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
   end Check_Cited_Evidence;

   ---------------------------------------------------------------------------
   --  The blast radius
   ---------------------------------------------------------------------------

   function Without_Md (Name : String) return String is
     (if Name'Length > 3 and then Name (Name'Last - 2 .. Name'Last) = ".md"
      then Name (Name'First .. Name'Last - 3)
      else Name);

   --  Deletes any blast radius log older than a week: one per session, and a
   --  session ends without coming back to clean up after itself.
   procedure Prune_Old_Seen_Files (State_Dir : String) is
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      Now    : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      use type Ada.Calendar.Time;
   begin
      Ada.Directories.Start_Search
        (Search, State_Dir, "synapse-blast-radius-seen-*",
         [Ada.Directories.Ordinary_File => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         begin
            if Now - Ada.Directories.Modification_Time (Item) >
              Seen_File_Max_Age
            then
               Ada.Directories.Delete_File (Ada.Directories.Full_Name (Item));
            end if;
         exception
            when others =>
               null;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
   exception
      when others =>
         null;
   end Prune_Old_Seen_Files;

   function Before (Left, Right : Unbounded_String) return Boolean is
     (Left < Right);

   package Sorting is new Core.Text_Lists.Vectors.Generic_Sorting (Before);

   function Blast_Radius
     (Env    : Environment; Vault : String; Ns : Common.Namespace;
      Owners : Core.Text_Lists.Vector; Rel, Sid : String)
      return Common.Maybe_Text
   is
      Home : constant Ports.Variables.Maybe_Value := Env.Vars.Get ("HOME");
   begin
      if not Home.Found then
         return (Found => False);
      end if;
      declare
         State_Dir : constant String :=
           To_String (Home.Value) & "/.claude/state";
         Seen_Path : constant String :=
           State_Dir & "/synapse-blast-radius-seen-" & Sid;
         Key       : constant String := To_String (Ns.Key) & "/" & Rel;
         Dir_Path  : constant String :=
           Vault & "/synapse/" & To_String (Ns.Key);
      begin
         begin
            Ada.Directories.Create_Path (State_Dir);
         exception
            when others =>
               null;
         end;
         Prune_Old_Seen_Files (State_Dir);

         declare
            Seen : constant Common.Maybe_Text := Read_Or_None (Seen_Path);
         begin
            if Seen.Found then
               declare
                  Text  : constant String := To_String (Seen.Value);
                  Start : Positive        := Text'First;
               begin
                  for I in Text'First .. Text'Last + 1 loop
                     if I > Text'Last or else Text (I) = LF then
                        if Text (Start .. I - 1) = Key then
                           return (Found => False);
                        end if;
                        Start := I + 1;
                     end if;
                  end loop;
               end;
            end if;
         end;

         --  Inbound typed relations in one pass over every node file.
         declare
            Dependents : Core.Text_Lists.Vector;
            Search     : Ada.Directories.Search_Type;
            Item       : Ada.Directories.Directory_Entry_Type;
         begin
            if not Ada.Directories.Exists (Dir_Path) then
               Complain
                 (Env,
                  "synapse-hook: could not open namespace dir, blast-radius " &
                  "check skipped (" & Dir_Path & ")" & LF);
               return (Found => False);
            end if;
            Ada.Directories.Start_Search
              (Search, Dir_Path, "*.md",
               [Ada.Directories.Ordinary_File => True, others => False]);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Item);
               declare
                  File : constant String := Ada.Directories.Simple_Name (Item);
               begin
                  if File /= "Index.md" then
                     declare
                        Source : constant String := Without_Md (File);
                        Node   : constant Common.Maybe_Text :=
                          Read_Or_None (Dir_Path & "/" & File);
                     begin
                        if Node.Found then
                           for E of Core.Node_Query.Edges
                             (To_String (Node.Value))
                           loop
                              for O of Owners loop
                                 declare
                                    Target : constant String :=
                                      Without_Md (To_String (O));
                                 begin
                                    --  A link to itself is not a dependent.
                                    if To_String (E.Target) = Target
                                      and then Source /= Target
                                    then
                                       Dependents.Append
                                         (To_Unbounded_String (Source));
                                       exit;
                                    end if;
                                 end;
                              end loop;
                           end loop;
                        end if;
                     end;
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
            if Dependents.Is_Empty then
               return (Found => False);
            end if;

            Sorting.Sort (Dependents);
            declare
               Unique : Core.Text_Lists.Vector;
            begin
               for D of Dependents loop
                  if Unique.Is_Empty or else Unique.Last_Element /= D then
                     Unique.Append (D);
                  end if;
               end loop;

               --  Recorded only once something was found, so a file with no
               --  dependents is checked again on a later edit.
               begin
                  Adapters.File_Bytes.Write
                    (Seen_Path,
                     (if Read_Or_None (Seen_Path).Found then
                        To_String (Read_Or_None (Seen_Path).Value)
                      else "") &
                     (if
                        Read_Or_None (Seen_Path).Found
                        and then Length (Read_Or_None (Seen_Path).Value) > 0
                        and then
                          Element
                            (Read_Or_None (Seen_Path).Value,
                             Length (Read_Or_None (Seen_Path).Value)) /=
                          LF
                      then "" & LF
                      else "") &
                     Key & LF);
               exception
                  when others =>
                     Complain
                       (Env,
                        "synapse-hook: could not write the 'seen' log, this " &
                        "relation may re-nudge (" & Seen_Path & ")" & LF);
               end;

               declare
                  Text  : Unbounded_String :=
                    To_Unbounded_String
                      ("This file is covered by a Synapse node that other " &
                       "nodes depend on:" & LF);
                  Total : constant Natural := Natural (Unique.Length);
               begin
                  for I in 1 .. Natural'Min (5, Total) loop
                     Append (Text, "  - " & To_String (Unique (I)) & LF);
                  end loop;
                  if Total > 5 then
                     Append
                       (Text,
                        "  (+" & Image.Image (Total - 5) & " more)" & LF);
                  end if;
                  Append
                    (Text,
                     LF & "Not necessarily a reason to change anything else " &
                     Dash & " just worth knowing before you finish, in case " &
                     "this edit changes behavior those nodes describe.");
                  return (Found => True, Value => Text);
               end;
            end;
         end;
      end;
   end Blast_Radius;

   ---------------------------------------------------------------------------
   --  The edit
   ---------------------------------------------------------------------------

   --  The physical path of the file's directory, plus its name: the root of
   --  the namespace is already resolved through symlinks and the path a tool
   --  reports may not be.
   function Real_Path (Path : String) return String is
      Slash : Natural := 0;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            Slash := I;
            exit;
         end if;
      end loop;
      declare
         Dir      : constant String :=
           (if Slash = 0 then "." elsif Slash = Path'First then "/"
            else Path (Path'First .. Slash - 1));
         Base     : constant String :=
           (if Slash = 0 then Path else Path (Slash + 1 .. Path'Last));
         Resolved : constant String :=
           GNAT.OS_Lib.Normalize_Pathname (Dir, Resolve_Links => True);
      begin
         return
           (if Resolved = "" then Path elsif Resolved = "/" then "/" & Base
            else Resolved & "/" & Base);
      end;
   exception
      when others =>
         return Path;
   end Real_Path;

   function Build
     (Env : Environment; Vault, Raw_File, Sid : String)
      return Common.Maybe_Text
   is
      Slash : Natural := 0;
   begin
      for I in reverse Raw_File'Range loop
         if Raw_File (I) = '/' then
            Slash := I;
            exit;
         end if;
      end loop;
      declare
         --  From the edited file's directory and not the working one: the two
         --  need not be in the same repository.
         Found_Ns : constant Common.Maybe_Namespace :=
           Common.Resolve_Namespace
             (Env,
              (if Slash = 0 then "." elsif Slash = Raw_File'First then "/"
               else Raw_File (Raw_File'First .. Slash - 1)));
      begin
         if not Found_Ns.Found then
            return (Found => False);
         end if;
         --  A delete has nothing to hash.
         if not Ada.Directories.Exists (Raw_File)
           or else Ada.Directories.Kind (Raw_File) /=
             Ada.Directories.Ordinary_File
         then
            return (Found => False);
         end if;
         declare
            Ns     : Common.Namespace renames Found_Ns.Value;
            File   : constant String := Real_Path (Raw_File);
            Prefix : constant String := To_String (Ns.Repo_Root) & "/";
         begin
            if File'Length <= Prefix'Length
              or else File (File'First .. File'First + Prefix'Length - 1) /=
                Prefix
            then
               return (Found => False);
            end if;
            declare
               Rel  : constant String            :=
                 File (File'First + Prefix'Length .. File'Last);
               Work : constant Common.Maybe_Text :=
                 Common.Work_Dir (Env, To_String (Ns.Key));
            begin
               if not Common.Namespace_Matches (Vault, Ns)
                 or else not Work.Found
               then
                  return (Found => False);
               end if;
               declare
                  Work_Dir       : constant String := To_String (Work.Value);
                  --  Independent of the code graph's coverage, so it is worked
                  --  out before any gate below and every return past this point
                  --  hands it back: an unmapped file is ordinary and must not
                  --  swallow a real finding.
                  Docstring_Note : constant Common.Maybe_Text :=
                    Check_Docstrings (Env, Work_Dir, Rel, File);
                  Index_Path     : constant String := Work_Dir & "/_index.bin";
                  Map            : Adapters.Index_Map.Map;
               begin
                  --  Checked before opening: opening a missing file answers
                  --  with an empty map, and an index nobody built would be
                  --  written out.
                  if not Ada.Directories.Exists (Index_Path) then
                     return Docstring_Note;
                  end if;
                  Adapters.Index_Map.Open (Map, Index_Path);
                  if Adapters.Index_Map.Discarded (Map) /=
                    Adapters.Index_Map.None
                  then
                     return Docstring_Note;
                  end if;
                  declare
                     Owned : constant Adapters.Index_Map.Maybe_Nodes :=
                       Adapters.Index_Map.Nodes_For (Map, Rel);
                  begin
                     if not Owned.Found then
                        --  New and unclaimed: queued for the unassigned sweep.
                        begin
                           declare
                              Added : constant Boolean :=
                                Adapters.Index_Map.Add_Unassigned (Map, Rel);
                              pragma Unreferenced (Added);
                           begin
                              null;
                           end;
                        exception
                           when others =>
                              Complain
                                (Env,
                                 "synapse-hook: could not queue '" & Rel &
                                 "' as unassigned" & LF);
                        end;
                        return Docstring_Note;
                     end if;
                     declare
                        Source   : constant Common.Maybe_Text :=
                          Read_Or_None (File);
                        Findings : Unbounded_String;
                        Stack    : Vault_Support.Store_Resolve.Stack;
                        Ok       : Boolean;
                     begin
                        if not Source.Found then
                           Complain
                             (Env,
                              "synapse-hook: could not read edited file, " &
                              "staleness check skipped (" & File & ")" & LF);
                           return Docstring_Note;
                        end if;
                        Vault_Support.Open (Env, "", Vault, Stack, Ok);
                        if not Ok then
                           return Docstring_Note;
                        end if;
                        for Node_File of Owned.Value loop
                           declare
                              Name : constant String := To_String (Node_File);
                              Node_Path : constant String            :=
                                Vault & "/synapse/" & To_String (Ns.Key) &
                                "/" & Name;
                              Node      : constant Common.Maybe_Text :=
                                Read_Or_None (Node_Path);
                           begin
                              if Node.Found then
                                 --  Before the staleness write whatever its
                                 --  outcome: a node already stale can still
                                 --  cite evidence this edit just invalidated.
                                 Check_Cited_Evidence
                                   (To_String (Node.Value), Name, Rel,
                                    To_String (Source.Value), Findings);
                                 declare
                                    Next    : Unbounded_String;
                                    Changed : Boolean;
                                 begin
                                    Core.Emit.Set_Stale_True
                                      (To_String (Node.Value), Next, Changed);
                                    --  Already stale, or no frontmatter: the
                                    --  file is not touched.
                                    if Changed then
                                       declare
                                          Wrote : constant Port.Write_Result :=
                                            Vault_Support.Store_Resolve.Store
                                              (Stack)
                                              .Write
                                              ("synapse/" &
                                               To_String (Ns.Key) & "/" & Name,
                                               To_String (Next));
                                          pragma Unreferenced (Wrote);
                                       begin
                                          null;
                                       exception
                                          when others =>
                                             null;
                                       end;
                                    end if;
                                 end;
                              end if;
                           end;
                        end loop;

                        declare
                           Blast : constant Common.Maybe_Text :=
                             Blast_Radius
                               (Env, Vault, Ns, Owned.Value, Rel, Sid);
                           Text  : Unbounded_String;
                        begin
                           --  Silence by design: an edit with no dependents
                           --  and no broken citation says nothing.
                           if Length (Findings) /= 0 then
                              Append
                                (Text,
                                 "You just edited a file that these Synapse " &
                                 "nodes cite as evidence, and the cited " &
                                 "range no longer matches what was recorded:" &
                                 LF & To_String (Findings));
                              Append
                                (Text,
                                 LF &
                                 "You have the code in front of you right " &
                                 "now, so checking is nearly free " & Dash &
                                 " this is the one moment correcting a node " &
                                 "costs nothing extra. If a sentence in the " &
                                 "node is now wrong, fix that sentence and " &
                                 "re-point the evidence, following the " &
                                 "synapse-node skill: recover the prose with " &
                                 "`synapse query body`, re-emit the crux and " &
                                 "grounded_in directives, and write it back " &
                                 "with `synapse write-node`." & LF & LF &
                                 "Keep it incidental. Correct only what this " &
                                 "edit actually contradicts. Do NOT re-read " &
                                 "the node's other sources, do not verify its " &
                                 "remaining claims, and do not start a sweep " &
                                 "" & Dash &
                                 " that is /synapse-rebuild-diff's " &
                                 "job, and turning this into one is how a " &
                                 "cheap habit becomes an expensive one. If the " &
                                 "prose still holds despite the range moving, " &
                                 "just re-point it and move on.");
                           end if;
                           if Blast.Found then
                              if Length (Findings) /= 0 then
                                 Append (Text, LF & LF & "---" & LF & LF);
                              end if;
                              Append (Text, Blast.Value);
                           end if;
                           if Docstring_Note.Found then
                              if Length (Text) /= 0 then
                                 Append (Text, LF & LF & "---" & LF & LF);
                              end if;
                              Append (Text, Docstring_Note.Value);
                           end if;
                           return
                             (if Length (Text) = 0 then (Found => False)
                              else (Found => True, Value => Text));
                        end;
                     end;
                  end;
               end;
            end;
         end;
      end;
   exception
      when others =>
         return (Found => False);
   end Build;

   procedure Run (Env : Environment) is
      Vault : constant Common.Maybe_Text := Common.Vault (Env);
   begin
      if not Vault.Found then
         return;
      end if;
      declare
         Payload : constant Common.Payload    := Common.Read (Env);
         File    : constant Common.Maybe_Text := Common.Tool_File (Payload);
         Sid     : constant Common.Maybe_Text :=
           Common.Str (Payload, "session_id");
      begin
         if not File.Found then
            return;
         end if;
         declare
            Text : constant Common.Maybe_Text :=
              Build
                (Env, To_String (Vault.Value), To_String (File.Value),
                 (if Sid.Found then To_String (Sid.Value) else "default"));
         begin
            if Text.Found then
               Common.Emit_Context
                 (Env, "PostToolUse", To_String (Text.Value));
            end if;
         end;
      end;
   end Run;

end Synapse.Hooks.Staleness;
