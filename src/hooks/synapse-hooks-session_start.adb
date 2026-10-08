with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.Command_Map;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Node_Query;
with Synapse.Core.Text_Lists;
with Synapse.Hooks.Stop_Nudge;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Variables;

package body Synapse.Hooks.Session_Start is

   use Ada.Strings.Unbounded;

   package Image renames Synapse.Core.Decimal_Image;
   package Runner renames Synapse.Ports.Process_Runner;

   LF    : constant Character := Character'Val (10);
   Label : constant String    := "Synapse Vault index";

   --  U+2014, spelled in UTF-8 bytes.
   Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   Largest : constant := 64 * 1_024 * 1_024;

   function Read_Or_None
     (Path : String; Limit : Natural) return Common.Maybe_Text
   is
   begin
      if not Ada.Directories.Exists (Path) then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value =>
           To_Unbounded_String (Adapters.File_Bytes.Read (Path, Limit)));
   exception
      when others =>
         return (Found => False);
   end Read_Or_None;

   --  The directory part of Path, or none when it has none.
   function Dirname (Path : String) return Common.Maybe_Text is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return
              (Found => True,
               Value =>
                 To_Unbounded_String
                   (if I = Path'First then "/"
                    else Path (Path'First .. I - 1)));
         end if;
      end loop;
      return (Found => False);
   end Dirname;

   --  `Name` in the plugin root, else the content root, else next to this
   --  program's own directory: `CLAUDE_PLUGIN_ROOT` is exported to a hook
   --  process however it was launched, `SYNAPSE_CONTENT_ROOT` is what an npm
   --  install sets since npm never sets the former, and the invoked path is
   --  all a setup that sets neither has.
   function Shipped_Path
     (Env : Environment; Name : String) return Common.Maybe_Text
   is
      Plugin  : constant Ports.Variables.Maybe_Value :=
        Env.Vars.Get ("CLAUDE_PLUGIN_ROOT");
      Content : constant Ports.Variables.Maybe_Value :=
        Env.Vars.Get ("SYNAPSE_CONTENT_ROOT");
      Bin_Dir : constant Common.Maybe_Text := Dirname (To_String (Env.Argv0));
   begin
      if Plugin.Found then
         return (Found => True, Value => Plugin.Value & "/" & Name);
      elsif Content.Found then
         return (Found => True, Value => Content.Value & "/" & Name);
      elsif Bin_Dir.Found then
         return (Found => True, Value => Bin_Dir.Value & "/../" & Name);
      end if;
      return (Found => False);
   end Shipped_Path;

   type Entry_Type is record
      Name, Remote : Unbounded_String;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors (Positive, Entry_Type);

   function Entry_Before (Left, Right : Entry_Type) return Boolean is
     (Left.Name < Right.Name);

   package Sorting is new Entry_Vectors.Generic_Sorting (Entry_Before);

   --  Every namespace of the vault with an index that names a remote, by name
   --  in byte order: the same text on every machine.
   function List_Namespaces (Vault : String) return Entry_Vectors.Vector is
      Root   : constant String := Vault & "/synapse";
      Result : Entry_Vectors.Vector;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      if not Ada.Directories.Exists (Root) then
         return Result;
      end if;
      Ada.Directories.Start_Search
        (Search, Root, "*",
         [Ada.Directories.Directory => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name  : constant String := Ada.Directories.Simple_Name (Item);
            Index : constant Common.Maybe_Text :=
              Read_Or_None (Root & "/" & Name & "/Index.md", Largest);
         begin
            if Index.Found then
               declare
                  Remote : constant Core.Node_Query.Maybe_Text :=
                    Core.Node_Query.Field (To_String (Index.Value), "remote");
               begin
                  if Remote.Found then
                     Result.Append
                       (Entry_Type'
                          (Name   => To_Unbounded_String (Name),
                           Remote => Remote.Value));
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      Sorting.Sort (Result);
      return Result;
   end List_Namespaces;

   --  How many nodes claim a file changed since the node was built: for each
   --  distinct `commit:` baseline of the namespace's nodes, one `git diff
   --  --name-only <commit>..HEAD`, checked against each node's own sources.
   --  A baseline that is not in local history is skipped, which `query drift`
   --  reports. Node frontmatter only is read; nothing is hashed.
   function Changed_Nodes
     (Env : Environment; Ns_Dir, Repo_Root : String) return Natural
   is
      type Baseline is record
         Commit : Unbounded_String;
         Paths  : Core.Text_Lists.Set;
         Usable : Boolean := False;
      end record;

      package Baseline_Vectors is new Ada.Containers.Vectors
        (Positive, Baseline);

      Baselines : Baseline_Vectors.Vector;
      Search    : Ada.Directories.Search_Type;
      Item      : Ada.Directories.Directory_Entry_Type;
      Changed   : Natural := 0;

      function Diff (Commit : String) return Baseline is
         Result  : Baseline;
         Options : Runner.Options;
         Args    : Core.Text_Lists.Vector;
      begin
         Result.Commit := To_Unbounded_String (Commit);
         Options.Cwd   := To_Unbounded_String (Repo_Root);
         Args.Append (To_Unbounded_String ("diff"));
         Args.Append (To_Unbounded_String ("--name-only"));
         Args.Append (To_Unbounded_String (Commit & "..HEAD"));
         declare
            Done : constant Runner.Result :=
              Env.Runner.Run ("git", Args, Options);
         begin
            if Runner.Succeeded (Done) then
               declare
                  Text  : constant String := To_String (Done.Output);
                  Start : Positive        := Text'First;
               begin
                  for I in Text'First .. Text'Last + 1 loop
                     if I > Text'Last or else Text (I) = LF then
                        if I > Start then
                           Result.Paths.Include (Text (Start .. I - 1));
                        end if;
                        Start := I + 1;
                     end if;
                  end loop;
               end;
               Result.Usable := not Result.Paths.Is_Empty;
            end if;
         end;
         return Result;
      exception
         when others =>
            return Result;
      end Diff;
   begin
      if not Ada.Directories.Exists (Ns_Dir) then
         return 0;
      end if;
      Ada.Directories.Start_Search
        (Search, Ns_Dir, "*.md",
         [Ada.Directories.Ordinary_File => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         if Ada.Directories.Simple_Name (Item) /= "Index.md" then
            declare
               Node : constant Common.Maybe_Text :=
                 Read_Or_None (Ada.Directories.Full_Name (Item), Largest);
            begin
               if Node.Found then
                  declare
                     Text   : constant String := To_String (Node.Value);
                     Commit : constant Core.Node_Query.Maybe_Text :=
                       Core.Node_Query.Field (Text, "commit");
                  begin
                     if Commit.Found and then Length (Commit.Value) > 0 then
                        declare
                           Index : Natural := 0;
                        begin
                           for I in 1 .. Natural (Baselines.Length) loop
                              if Baselines (I).Commit = Commit.Value then
                                 Index := I;
                                 exit;
                              end if;
                           end loop;
                           if Index = 0 then
                              Baselines.Append
                                (Diff (To_String (Commit.Value)));
                              Index := Natural (Baselines.Length);
                           end if;
                           if Baselines (Index).Usable then
                              for P of Core.Node_Query.Sources (Text) loop
                                 if Baselines (Index).Paths.Contains
                                     (To_String (P))
                                 then
                                    Changed := Changed + 1;
                                    exit;
                                 end if;
                              end loop;
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
      Ada.Directories.End_Search (Search);
      return Changed;
   exception
      when others =>
         return 0;
   end Changed_Nodes;

   --  The namespaces recorded against Remote, which is this same repository
   --  built on another branch, and how to read one without switching. None
   --  when there are none; an empty remote identifies nothing.
   function Sibling_Line
     (Vault : String; Entries : Entry_Vectors.Vector; Remote : String)
      return Common.Maybe_Text
   is
      Names : Unbounded_String;
      First : Unbounded_String;
   begin
      if Remote = "" then
         return (Found => False);
      end if;
      for E of Entries loop
         if To_String (E.Remote) = Remote then
            if Length (First) /= 0 then
               Append (Names, ", ");
            end if;
            Append (Names, Vault & "/synapse/" & To_String (E.Name) & "/");
            if Length (First) = 0 then
               First := E.Name;
            end if;
         end if;
      end loop;
      if Length (First) = 0 then
         return (Found => False);
      end if;
      declare
         Ns : constant String := To_String (First);
      begin
         return
           (Found => True,
            Value =>
              To_Unbounded_String
                ("This repo does have a graph on another branch: " &
                 To_String (Names) & ". Consult it before grepping -- " &
                 "`synapse query --namespace " & Ns & " body ""<Node>""`, " &
                 "`synapse index lookup <path> --namespace " & Ns & "`, " &
                 "`synapse callers <name> --namespace " & Ns &
                 "` (Index.md: " & Vault & "/synapse/" & Ns &
                 "/Index.md). It describes that " &
                 "branch, so read code this branch changed from the working " &
                 "tree; `stale`/`drift` against this checkout also need " &
                 "SYNAPSE_REPO_ROOT set to it."));
      end;
   end Sibling_Line;

   --  Every namespace but Own and, when set, those recorded against
   --  Skip_Remote (already named by the sibling line). None when nothing is
   --  left to list.
   function Catalogue
     (Vault       : String; Entries : Entry_Vectors.Vector; Own : String;
      Skip_Remote : String; Has_Skip : Boolean) return Common.Maybe_Text
   is
      Text  : Unbounded_String;
      Wrote : Boolean := False;
   begin
      for E of Entries loop
         if (Own = "" or else To_String (E.Name) /= Own)
           and then not (Has_Skip and then To_String (E.Remote) = Skip_Remote)
         then
            if not Wrote then
               Append
                 (Text,
                  "Other Synapse namespaces in this vault (name | remote). A " &
                  "session that moves into one of these repos can consult " &
                  Vault & "/synapse/{name}/Index.md for its code graph -- " &
                  "but verify the listed remote against that repo's own " &
                  "`git remote get-url origin` first, since a namespace is " &
                  "keyed by repo and branch and names only the branch it was " &
                  "built from:" & LF);
            else
               Append (Text, "" & LF);
            end if;
            Append (Text, To_String (E.Name) & "|" & To_String (E.Remote));
            Wrote := True;
         end if;
      end loop;
      return
        (if Wrote then (Found => True, Value => Text) else (Found => False));
   end Catalogue;

   function Build (Env : Environment; Cwd : String) return Common.Maybe_Text is
      Vault_Dir : constant Common.Maybe_Text := Common.Vault (Env);
      Vault     : constant String            :=
        (if Vault_Dir.Found then To_String (Vault_Dir.Value) else "");

      Claude_Md, Vault_Warning, Base, Synapse_Line,
      Catalogue_Text   : Unbounded_String;
      Absent, Siblings : Common.Maybe_Text;
      Found_Ns         : Common.Maybe_Namespace;
   begin
      --  Synapse's own standing instructions, independent of the vault.
      declare
         Where   : constant Common.Maybe_Text :=
           Shipped_Path (Env, "synapse-claude.md");
         Content : constant Common.Maybe_Text :=
           (if Where.Found then
              Read_Or_None (To_String (Where.Value), 1_024 * 1_024)
            else (Found => False));
      begin
         if Content.Found then
            Claude_Md := Content.Value;
         end if;
      end;

      --  The one precondition every other section here depends on, said and
      --  not implied by silence: nothing at install time prints anything.
      if Vault = "" then
         Vault_Warning :=
           To_Unbounded_String
             ("Synapse Vault isn't configured, or its directory isn't " &
              "reachable -- code-graph and vault-note features are " &
              "unavailable until synapse.conf's SYNAPSE_VAULT_DIR points at " &
              "a real directory. Create or edit synapse.conf at " &
              "$XDG_CONFIG_HOME/synapse/synapse.conf (or " &
              "~/.config/synapse/synapse.conf if that variable isn't set), " &
              "or ~/.claude/synapse.conf.");
      else
         Found_Ns := Common.Resolve_Namespace (Env, Cwd);
      end if;

      declare
         Entries : Entry_Vectors.Vector;
      begin
         if Vault /= "" then
            if Found_Ns.Found then
               declare
                  Ns       : constant Common.Namespace  := Found_Ns.Value;
                  Index_At : constant String            :=
                    Vault & "/synapse/" & To_String (Ns.Key) & "/Index.md";
                  Index    : constant Common.Maybe_Text :=
                    Read_Or_None (Index_At, Largest);
               begin
                  if Index.Found then
                     declare
                        Recorded : constant Core.Node_Query.Maybe_Text :=
                          Core.Node_Query.Field
                            (To_String (Index.Value), "remote");
                        Existing : constant String                     :=
                          (if Recorded.Found then To_String (Recorded.Value)
                           else "");
                     begin
                        if Existing = To_String (Ns.Remote) then
                           --  The question-to-command map rides along once per
                           --  session and not per prompt: a per prompt line is
                           --  billed on every turn, and a command a session
                           --  does not know costs a `--help` discovery turn.
                           declare
                              Ns_Dir  : constant String  :=
                                Vault & "/synapse/" & To_String (Ns.Key);
                              Changed : constant Natural :=
                                Changed_Nodes
                                  (Env, Ns_Dir, To_String (Ns.Repo_Root));
                           begin
                              Append
                                (Synapse_Line,
                                 "Synapse namespace for this repo and branch: " &
                                 Index_At & " -- consult it for existing " &
                                 "code-graph nodes before re-exploring from " &
                                 "scratch." & LF);
                              if Changed > 0 then
                                 Append
                                   (Synapse_Line,
                                    Image.Image (Changed) & " graph node" &
                                    (if Changed = 1 then "" else "s") &
                                    " cover" &
                                    (if Changed = 1 then "s" else "") &
                                    " files changed since " &
                                    (if Changed = 1 then "it was"
                                     else "they were") &
                                    " built -- /synapse-rebuild-diff brings " &
                                    "the graph up to date." & LF);
                              end if;
                              Append (Synapse_Line, Core.Command_Map.Render);
                           end;
                        else
                           Synapse_Line :=
                             To_Unbounded_String
                               ("Synapse namespace synapse/" &
                                To_String (Ns.Key) &
                                "/ exists but its remote (""" & Existing &
                                """) doesn't match this repo's (""" &
                                To_String (Ns.Remote) &
                                """) -- either a different repo sharing this " &
                                "name, or this repo's remote changed. Skipping " &
                                "the pointer rather than risk cross-project " &
                                "contamination. If the remote changed " &
                                "deliberately, rebuild the namespace with " &
                                "/synapse-rebuild-full.");
                        end if;
                     end;
                  else
                     --  A branch with no namespace is ordinary, and must stay
                     --  distinguishable from a namespace that found nothing.
                     Absent :=
                       (Found => True,
                        Value =>
                          To_Unbounded_String
                            ("synapse/" & To_String (Ns.Key) & "/"));
                  end if;
               end;
            end if;
            Entries := List_Namespaces (Vault);
            --  Siblings are looked for only when this branch has no namespace
            --  of its own: with one, the pointer names the graph to read.
            if Absent.Found and then Found_Ns.Found then
               Siblings :=
                 Sibling_Line
                   (Vault, Entries, To_String (Found_Ns.Value.Remote));
            end if;
            declare
               Skip : constant Boolean           := Siblings.Found;
               Cat  : constant Common.Maybe_Text :=
                 Catalogue
                   (Vault, Entries,
                    (if Found_Ns.Found then To_String (Found_Ns.Value.Key)
                     else ""),
                    (if Found_Ns.Found then To_String (Found_Ns.Value.Remote)
                     else ""),
                    Skip);
            begin
               if Cat.Found then
                  Catalogue_Text := Cat.Value;
               end if;
            end;
         end if;
      end;

      if Vault /= "" then
         declare
            Index_Path : constant String            := Vault & "/Index.md";
            Content    : constant Common.Maybe_Text :=
              Read_Or_None (Index_Path, Largest);
         begin
            if Content.Found then
               Base :=
                 To_Unbounded_String
                   (Label & " (" & Index_Path & ") " & Dash &
                    " read before creating or " &
                    "linking any note; prefer linking to an existing note " &
                    "over duplicating content, and fall back to linking " &
                    "this index if nothing more specific applies:" & LF & LF) &
                 Content.Value;
            else
               --  The vault is known to be a directory, so a failure here is
               --  a missing index and not an unreachable vault. Offered and
               --  not seeded: that is the agent's call to make.
               declare
                  Template : constant Common.Maybe_Text :=
                    Shipped_Path (Env, "Index.md.template");
               begin
                  Base :=
                    To_Unbounded_String
                      ("No Index.md found at " & Index_Path & " -- the " &
                       "configured Synapse Vault has no index yet. Offer to " &
                       "seed it from the shipped default (" &
                       (if Template.Found then To_String (Template.Value)
                        else "this plugin's own Index.md.template") &
                       ") before creating or linking any note.");
               end;
            end if;
         end;
      end if;

      --  Only worth saying alongside something else: alone it is a hook
      --  announcing it has nothing to announce. A sibling to point at is
      --  always worth saying.
      if Absent.Found then
         if Siblings.Found then
            Synapse_Line :=
              To_Unbounded_String
                ("No Synapse namespace covers " & To_String (Absent.Value) &
                 " -- this branch has no code graph of its own, and a " &
                 "short-lived branch does not need one. ") &
              Siblings.Value;
         elsif Length (Base) /= 0 or else Length (Catalogue_Text) /= 0 then
            Synapse_Line :=
              To_Unbounded_String
                ("No Synapse namespace covers " & To_String (Absent.Value) &
                 " -- this branch has no code graph. That is normal; " &
                 "/synapse-init builds one if it is worth it. Nothing here " &
                 "is stale, there is simply nothing to consult.");
         end if;
      end if;

      declare
         Text  : Unbounded_String;
         Wrote : Boolean := False;

         procedure Add (Part : Unbounded_String) is
         begin
            if Length (Part) > 0 then
               if Wrote then
                  Append (Text, "" & LF & LF);
               end if;
               Append (Text, Part);
               Wrote := True;
            end if;
         end Add;
      begin
         Add (Claude_Md);
         Add (Vault_Warning);
         Add (Base);
         Add (Synapse_Line);
         Add (Catalogue_Text);
         return
           (if Wrote then (Found => True, Value => Text)
            else (Found => False));
      end;
   exception
      when others =>
         return (Found => False);
   end Build;

   procedure Run (Env : Environment) is
      Payload : constant Common.Payload    := Common.Read (Env);
      Cwd     : constant Common.Maybe_Text := Common.Str (Payload, "cwd");
   begin
      --  Detached, so this never waits on the network; `vault-pull` itself
      --  does nothing without a vault, a git backend or a remote.
      Stop_Nudge.Spawn_Pull (Env);
      declare
         Text : constant Common.Maybe_Text :=
           Build (Env, (if Cwd.Found then To_String (Cwd.Value) else "."));
      begin
         if Text.Found then
            Common.Emit_Context (Env, "SessionStart", To_String (Text.Value));
         end if;
      end;
   end Run;

end Synapse.Hooks.Session_Start;
