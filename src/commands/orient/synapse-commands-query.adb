with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Index_Map;
with Synapse.Adapters.Tags_Cache;
with Synapse.Commands.Build_Lists;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Context;
with Synapse.Commands.Graph_Support;
with Synapse.Commands.Tags_Cache;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Drift;
with Synapse.Core.Hashing;
with Synapse.Core.Line_Slice;
with Synapse.Core.Node_Format;
with Synapse.Core.Node_Query;
with Synapse.Core.Symbol;
with Synapse.Core.Tag_Line;
with Synapse.Core.Verify;
with Synapse.Ports.Process_Runner;

package body Synapse.Commands.Query is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;
   package Node_Query renames Synapse.Core.Node_Query;
   package Drift renames Synapse.Core.Drift;
   package Verify renames Synapse.Core.Verify;
   package Runner renames Synapse.Ports.Process_Runner;
   package Image renames Synapse.Core.Decimal_Image;
   package Cache_Adapter renames Synapse.Adapters.Tags_Cache;

   use type Adapters.Index_Map.Issue;
   use type Cache_Adapter.Issue;
   use type Verify.Staleness_Kind;

   Prog : constant String    := "synapse-query";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse query [--namespace <repo>@<branch>] <subcommand> [args]" &
     LF & LF &
     "  --namespace <repo>@<branch>        address another checkout's " &
     "graph, not the cwd's" & LF &
     "  body    <node>                     brief: summary, crux pointer, " &
     "Links" & LF &
     "  body    <node> --full              the whole generated prose, no " &
     "frontmatter" & LF &
     "  body    <node> --lines <a-b>[,<c-d>...]  those lines of the node " &
     "file, frontmatter included" & LF &
     "  sources <node>                     every path the node covers" & LF &
     "  sources <node> --count             just the number" & LF &
     "  sources <node> --modules           module<TAB>count, byte sorted" &
     LF &
     "  sources <node> --filter <pattern>  matching paths only (substring)" &
     LF & "  field   <node> <key>               one top-level frontmatter " &
     "scalar" & LF &
     "  field   --file <path> <key>        same, from a file directly -- " &
     "no vault node needed" & LF &
     "  stale                              nodes whose files no longer " &
     "match" & LF &
     "  drift                              what changed since each node's " &
     "commit" & LF &
     "  grounding                          nodes whose evidence no longer " &
     "matches" & LF &
     "  grounding <node> --list            that node's groundings, " &
     "path<TAB>lines" & LF &
     "  links   <node>                     outbound relations, " &
     "relation<TAB>target" & LF &
     "  links   <node> --inbound           what points here, " &
     "relation<TAB>source" & LF &
     "  links   <node> --closure           reachable outbound, " &
     "depth<TAB>node" & LF &
     "  links   --check                    link targets that resolve to no " &
     "node" & LF & "  symbol  <name> <node>              exact-name hits, " &
     "name<TAB>role<TAB>kind<TAB>path:line<TAB>expression" & LF;

   function Usage (Env : Environment) return Exit_Code is
   begin
      Complain (Env, Usage_Text);
      Cli_Args.Print_Map_For (Env, "query");
      return 2;
   end Usage;

   function Is_Blank (Item : Unbounded_String) return Boolean is
     (Length (Item) = 0);

   --  The node's text, or none: exit 1 for an unknown node is "no
   --  information" and never "clean".
   function Need
     (Ctx : Context.Context; Name : String) return Context.Maybe_Text is
     (Context.Read_Node (Ctx, Name));

   function Before (Left, Right : Unbounded_String) return Boolean is
     (Left < Right);

   package Sorting is new Lists.Vectors.Generic_Sorting (Before);

   ---------------------------------------------------------------------------
   --  body
   ---------------------------------------------------------------------------

   function Cmd_Body
     (Env : Environment; Ctx : Context.Context; Rest : Lists.Vector)
      return Exit_Code
   is
      Mode_Brief : constant Boolean := Natural (Rest.Length) = 1;
      Mode_Full  : constant Boolean :=
        Natural (Rest.Length) = 2 and then To_String (Rest (2)) = "--full";
      Mode_Lines : constant Boolean :=
        Natural (Rest.Length) = 3 and then To_String (Rest (2)) = "--lines";
   begin
      if Rest.Is_Empty or else Is_Blank (Rest (1))
        or else not (Mode_Brief or else Mode_Full or else Mode_Lines)
      then
         return Usage (Env);
      end if;
      declare
         Name   : constant String                  := To_String (Rest (1));
         Spec   : constant String                  :=
           (if Mode_Lines then To_String (Rest (3)) else "");
         Ranges : constant Node_Query.Maybe_Ranges :=
           (if Mode_Lines then Node_Query.Parse_Line_Ranges (Spec)
            else (Found => False));
      begin
         if Mode_Lines and then not Ranges.Found then
            Complain
              (Env,
               Prog & ": --lines expects ranges like 12-14,40-41,88, got '" &
               Spec & "'" & LF);
            return 2;
         end if;
         declare
            Node : constant Context.Maybe_Text := Need (Ctx, Name);
         begin
            if not Node.Found then
               return 1;
            end if;
            declare
               Text : constant String := To_String (Node.Value);
            begin
               if Mode_Lines then
                  declare
                     Cut : constant Node_Query.Maybe_Text :=
                       Node_Query.Lines_In (Text, Ranges.Value);
                  begin
                     if not Cut.Found then
                        Complain
                          (Env,
                           Prog & ": --lines " & Spec &
                           " starts past the last line of '" & Name & "'" &
                           LF);
                        return 1;
                     end if;
                     Say (Env, To_String (Cut.Value));
                     return 0;
                  end;
               elsif Mode_Brief then
                  declare
                     Brief : constant Node_Query.Maybe_Text :=
                       Node_Query.Brief (Text);
                  begin
                     if Brief.Found then
                        Say (Env, To_String (Brief.Value));
                        return 0;
                     end if;
                  end;
               else
                  declare
                     Inner : constant Node_Query.Maybe_Text :=
                       Node_Query.Body_Of (Text);
                  begin
                     if Inner.Found then
                        if Length (Inner.Value) /= 0 then
                           Say (Env, To_String (Inner.Value) & LF);
                        end if;
                        return 0;
                     end if;
                  end;
               end if;
               --  A node from before the fence was written: said, since its
               --  `## Notes` are part of what follows.
               Complain
                 (Env,
                  Prog & ": no generated fence in '" & Name &
                  "'; printing everything after the frontmatter" & LF);
               Say (Env, Node_Query.Body_After_Frontmatter (Text));
               return 0;
            end;
         end;
      end;
   end Cmd_Body;

   ---------------------------------------------------------------------------
   --  sources
   ---------------------------------------------------------------------------

   function Cmd_Sources
     (Env : Environment; Ctx : Context.Context; Rest : Lists.Vector)
      return Exit_Code
   is
      type Mode_Kind is (All_Paths, Count_Only, Modules, Filter);
      Mode    : Mode_Kind        := All_Paths;
      Pattern : Unbounded_String;
      Given   : constant Natural := Natural (Rest.Length);
   begin
      if Rest.Is_Empty or else Is_Blank (Rest (1)) then
         return Usage (Env);
      end if;
      if Given > 1 then
         declare
            Flag : constant String := To_String (Rest (2));
         begin
            if Flag = "--count" and then Given = 2 then
               Mode := Count_Only;
            elsif Flag = "--modules" and then Given = 2 then
               Mode := Modules;
            elsif Flag = "--filter" and then Given = 3
              and then not Is_Blank (Rest (3))
            then
               Mode    := Filter;
               Pattern := Rest (3);
            else
               return Usage (Env);
            end if;
         end;
      end if;
      declare
         Node : constant Context.Maybe_Text :=
           Need (Ctx, To_String (Rest (1)));
      begin
         if not Node.Found then
            return 1;
         end if;
         declare
            Paths : constant Lists.Vector :=
              Node_Query.Sources (To_String (Node.Value));
         begin
            case Mode is
               when All_Paths =>
                  for P of Paths loop
                     Say (Env, To_String (P) & LF);
                  end loop;

               when Count_Only =>
                  Say (Env, Image.Image (Natural (Paths.Length)) & LF);

               when Filter =>
                  --  `grep -F`: a substring and not a pattern.
                  for P of Paths loop
                     if Ada.Strings.Fixed.Index
                         (To_String (P), To_String (Pattern)) >
                       0
                     then
                        Say (Env, To_String (P) & LF);
                     end if;
                  end loop;

               when Modules =>
                  for M of Node_Query.Module_Counts (Paths, Ctx.Chains) loop
                     Say
                       (Env,
                        To_String (M.Module) & HT & Image.Image (M.Count) &
                        LF);
                  end loop;
            end case;
            return 0;
         end;
      end;
   end Cmd_Sources;

   ---------------------------------------------------------------------------
   --  field
   ---------------------------------------------------------------------------

   function Write_Field
     (Env : Environment; Text, Key : String) return Exit_Code
   is
   begin
      if Key = "sources" then
         Complain
           (Env,
            Prog & ": 'sources' is a list, not a scalar field -- use: " &
            "synapse query sources <node>" & LF);
         return 2;
      end if;
      --  An absent key prints nothing and exits 0.
      declare
         Value : constant Node_Query.Maybe_Text :=
           Node_Query.Field (Text, Key);
      begin
         if Value.Found then
            Say (Env, To_String (Value.Value) & LF);
         end if;
         return 0;
      end;
   end Write_Field;

   function Field_Of_File
     (Env : Environment; Path, Key : String) return Exit_Code
   is
      Text  : Unbounded_String;
      Found : Boolean;
   begin
      Support.Read_File (Path, 256 * 1_024 * 1_024, Text, Found);
      if not Found then
         Complain (Env, Prog & ": no such file: " & Path & LF);
         return 1;
      end if;
      return Write_Field (Env, To_String (Text), Key);
   end Field_Of_File;

   function Cmd_Field
     (Env : Environment; Ctx : Context.Context; Rest : Lists.Vector)
      return Exit_Code
   is
   begin
      if Natural (Rest.Length) /= 2 or else Is_Blank (Rest (1))
        or else Is_Blank (Rest (2))
      then
         return Usage (Env);
      end if;
      declare
         Path : constant String :=
           Context.Node_Path (Ctx, To_String (Rest (1)));
      begin
         return Field_Of_File (Env, Path, To_String (Rest (2)));
      end;
   end Cmd_Field;

   ---------------------------------------------------------------------------
   --  What the checkout's files and git say
   ---------------------------------------------------------------------------

   --  `stale`, `drift`, `grounding` and `symbol` read the real files of the
   --  checkout, which an explicit namespace with no root cannot offer.
   function Repo_Root_Present
     (Env : Environment; Ctx : Context.Context; Sub : String) return Boolean
   is
   begin
      if not Ctx.Namespace_Explicit or else Length (Ctx.Repo_Root) /= 0 then
         return True;
      end if;
      Complain
        (Env,
         Prog & ": '" & Sub & "' needs " & To_String (Ctx.Namespace) &
         "'s real files on disk -- set SYNAPSE_REPO_ROOT to its working " &
         "tree" & LF);
      return False;
   end Repo_Root_Present;

   function Git_Args
     (A1, A2, A3, A4, A5, A6 : String := "") return Lists.Vector
   is
      Result : Lists.Vector;
   begin
      for Index in 1 .. 6 loop
         declare
            Text : constant String :=
              (case Index is when 1 => A1, when 2 => A2, when 3 => A3,
                 when 4 => A4, when 5 => A5, when others => A6);
         begin
            if Text /= "" then
               Result.Append (To_Unbounded_String (Text));
            end if;
         end;
      end loop;
      return Result;
   end Git_Args;

   function Trimmed (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Text (First) in ' ' | HT | ASCII.CR | LF
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) in ' ' | HT | ASCII.CR | LF loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   --  git in the checkout: its standard output, and whether it succeeded.
   procedure Git
     (Env    :     Environment; Ctx : Context.Context; Args : Lists.Vector;
      Output : out Unbounded_String; Ok : out Boolean)
   is
      Options : Runner.Options;
   begin
      Options.Cwd := Ctx.Repo_Root;
      declare
         Done : constant Runner.Result :=
           Env.Runner.Run ("git", Args, Options);
      begin
         Output := Done.Output;
         Ok     := Runner.Succeeded (Done);
      end;
   exception
      when Runner.Process_Failure =>
         Output := Null_Unbounded_String;
         Ok     := False;
   end Git;

   function Git_Ok
     (Env : Environment; Ctx : Context.Context; Args : Lists.Vector)
      return Boolean
   is
      Ignored : Unbounded_String;
      Ok      : Boolean;
   begin
      Git (Env, Ctx, Args, Ignored, Ok);
      return Ok;
   end Git_Ok;

   function Count_Of
     (Env : Environment; Ctx : Context.Context; Spec : String) return Natural
   is
      Output : Unbounded_String;
      Ok     : Boolean;
   begin
      Git (Env, Ctx, Git_Args ("rev-list", "--count", Spec), Output, Ok);
      if not Ok then
         return 0;
      end if;
      return Natural'Value (Trimmed (To_String (Output)));
   exception
      when others =>
         return 0;
   end Count_Of;

   ---------------------------------------------------------------------------
   --  The nodes the index says exist
   ---------------------------------------------------------------------------

   --  The names of the nodes of the index, which is authoritative for which
   --  exist; each node's own `sources` stays authoritative for what it
   --  covers. Found is false when there is no usable index.
   procedure Node_Names
     (Ctx   :     Context.Context; Map : in out Adapters.Index_Map.Map;
      Names : out Lists.Vector; Found : out Boolean)
   is
   begin
      Adapters.Index_Map.Open (Map, To_String (Ctx.Work_Dir) & "/_index.bin");
      if Adapters.Index_Map.Discarded (Map) /= Adapters.Index_Map.None then
         Found := False;
         return;
      end if;
      Names := Adapters.Index_Map.Node_Names (Map);
      Found := True;
   end Node_Names;

   ---------------------------------------------------------------------------
   --  stale
   ---------------------------------------------------------------------------

   function Cmd_Stale
     (Env : Environment; Ctx : Context.Context; Rest : Lists.Vector)
      return Exit_Code
   is
      Map   : Adapters.Index_Map.Map;
      Names : Lists.Vector;
      Found : Boolean;
      Root  : constant String := To_String (Ctx.Repo_Root);
   begin
      if not Rest.Is_Empty then
         return Usage (Env);
      end if;
      if not Repo_Root_Present (Env, Ctx, "stale") then
         return 1;
      end if;
      Node_Names (Ctx, Map, Names, Found);
      if not Found then
         return 1;
      end if;
      for Node_File of Names loop
         declare
            File                   : constant String := To_String (Node_File);
            Node                   : constant Context.Maybe_Text :=
              Context.Read_Node (Ctx, File);
            Paths, Missing, Hashes : Lists.Vector;
            Stored                 : Node_Query.Maybe_Text;
         begin
            if Node.Found then
               Stored :=
                 Node_Query.Field (To_String (Node.Value), "sources_digest");
               Paths  := Node_Query.Sources (To_String (Node.Value));
               for P of Paths loop
                  declare
                     Content : Unbounded_String;
                     Have    : Boolean;
                  begin
                     Support.Read_Repo_File
                       (Root, To_String (P), Content, Have);
                     if Have then
                        Hashes.Append
                          (To_Unbounded_String
                             (Core.Hashing.Blob_Hash_Hex
                                (To_String (Content))));
                     else
                        Missing.Append (P);
                     end if;
                  end;
               end loop;
            end if;
            declare
               State : constant Verify.Staleness :=
                 Verify.Check
                   (Node.Found,
                    Stored.Found and then Length (Stored.Value) /= 0,
                    (if Stored.Found then To_String (Stored.Value) else ""),
                    Paths, Missing, Hashes);
            begin
               if State.Kind /= Verify.Clean then
                  Say
                    (Env,
                     Context.Strip_Md (File) & HT & Verify.Reason (State) &
                     LF);
               end if;
            end;
         end;
      end loop;
      return 0;
   end Cmd_Stale;

   ---------------------------------------------------------------------------
   --  drift
   ---------------------------------------------------------------------------

   --  One baseline commit and what is derived from it, once for every node
   --  that shares it: the diff is the expensive part.
   type Baseline is record
      Commit    : Unbounded_String;
      Changes   : Drift.Diff;
      Divergent : Boolean := False;
      Dirty     : Boolean := False;
   end record;

   package Baseline_Vectors is new Ada.Containers.Vectors (Positive, Baseline);

   type Pairing is record
      Node  : Unbounded_String;
      Base  : Positive;
      Paths : Lists.Vector;
   end record;

   package Pairing_Vectors is new Ada.Containers.Vectors (Positive, Pairing);

   --  `git cat-file -e <commit>^{commit}`: is the baseline in local history?
   --  A shallow clone says no, which is a finding and not an error.
   function Commit_Exists
     (Env : Environment; Ctx : Context.Context; Commit : String)
      return Boolean is
     (Git_Ok (Env, Ctx, Git_Args ("cat-file", "-e", Commit & "^{commit}")));

   function Is_Ancestor
     (Env : Environment; Ctx : Context.Context; Commit : String)
      return Boolean is
     (Git_Ok
        (Env, Ctx, Git_Args ("merge-base", "--is-ancestor", Commit, "HEAD")));

   --  `git rev-list --left-right --count <base>...HEAD`.
   procedure Left_Right
     (Env         :     Environment; Ctx : Context.Context; Commit : String;
      Left, Right : out Natural)
   is
      Output : Unbounded_String;
      Ok     : Boolean;
   begin
      Left  := 0;
      Right := 0;
      Git
        (Env, Ctx,
         Git_Args ("rev-list", "--left-right", "--count", Commit & "...HEAD"),
         Output, Ok);
      if not Ok then
         return;
      end if;
      declare
         Text : constant String := Trimmed (To_String (Output));
         Cut  : Natural         := Text'First;
      begin
         while Cut <= Text'Last and then Text (Cut) not in ' ' | HT loop
            Cut := Cut + 1;
         end loop;
         Left  := Natural'Value (Text (Text'First .. Cut - 1));
         Right := Natural'Value (Trimmed (Text (Cut .. Text'Last)));
      end;
   exception
      when others =>
         null;
   end Left_Right;

   function Upstream_Name
     (Env : Environment; Ctx : Context.Context) return String
   is
      Output : Unbounded_String;
      Ok     : Boolean;
   begin
      Git
        (Env, Ctx,
         Git_Args
           ("rev-parse", "--abbrev-ref", "--symbolic-full-name",
            "@{upstream}"),
         Output, Ok);
      return (if Ok then Trimmed (To_String (Output)) else "");
   end Upstream_Name;

   --  The index of Commit among Baselines, adding it with its diff when it is
   --  new.
   function Baseline_For
     (Env           :        Environment; Ctx : Context.Context;
      Baselines     : in out Baseline_Vectors.Vector; Commit : String;
      Repo_Findings : in out Unbounded_String) return Positive
   is
   begin
      for I in 1 .. Natural (Baselines.Length) loop
         if To_String (Baselines (I).Commit) = Commit then
            return I;
         end if;
      end loop;
      declare
         Output    : Unbounded_String;
         Ok        : Boolean;
         Entry_Out : Baseline;
      begin
         Git
           (Env, Ctx,
            Git_Args ("diff", "--name-status", "-M", Commit & "..HEAD"),
            Output, Ok);
         --  A failed diff counts as empty; the divergence is reported apart.
         Entry_Out.Commit    := To_Unbounded_String (Commit);
         Entry_Out.Changes   :=
           Drift.Parse_Name_Status (if Ok then To_String (Output) else "");
         Entry_Out.Divergent := not Is_Ancestor (Env, Ctx, Commit);
         if Entry_Out.Divergent then
            --  Its own finding: the graph was built off a line this checkout
            --  is not on.
            declare
               Left, Right : Natural;
            begin
               Left_Right (Env, Ctx, Commit, Left, Right);
               Append
                 (Repo_Findings,
                  "(repo)" & HT & "baseline " & Drift.Short_Commit (Commit) &
                  " is not an ancestor of HEAD: " & Image.Image (Left) &
                  " commits only on the baseline, " & Image.Image (Right) &
                  " only here -- the graph describes a different line" & LF);
            end;
         end if;
         Baselines.Append (Entry_Out);
         return Natural (Baselines.Length);
      end;
   end Baseline_For;

   --  `_manifest.tsv` from the vault, or the work directory's copy.
   procedure Read_Manifest
     (Ctx : Context.Context; Text : out Unbounded_String; Found : out Boolean)
   is
      Limit : constant := 64 * 1_024 * 1_024;
   begin
      Support.Read_File
        (To_String (Ctx.Abs_Dir) & "/_manifest.tsv", Limit, Text, Found);
      if not Found then
         Support.Read_File
           (To_String (Ctx.Work_Dir) & "/manifest.tsv", Limit, Text, Found);
      end if;
   end Read_Manifest;

   --  Added paths no node claims, split by whether a manifest pattern would
   --  already cover them.
   procedure Report_Added_Paths
     (Env           :        Environment; Ctx : Context.Context;
      Map : in out Adapters.Index_Map.Map; Baselines : Baseline_Vectors.Vector;
      Repo_Findings : in out Unbounded_String)
   is
      Added : Lists.Vector;
   begin
      for B of Baselines loop
         Added.Append_Vector (B.Changes.Added);
      end loop;
      if Added.Is_Empty then
         return;
      end if;
      Sorting.Sort (Added);

      declare
         Unclaimed : Unbounded_String;
         Count     : Natural := 0;
         Previous  : Unbounded_String;
         First     : Boolean := True;
      begin
         for P of Added loop
            if First or else P /= Previous then
               First    := False;
               Previous := P;
               if not Adapters.Index_Map.Nodes_For (Map, To_String (P)).Found
               then
                  Append (Unclaimed, To_String (P) & LF);
                  Count := Count + 1;
               end if;
            end if;
         end loop;
         if Count = 0 then
            return;
         end if;

         declare
            Manifest : Unbounded_String;
            Have     : Boolean;
         begin
            Read_Manifest (Ctx, Manifest, Have);
            if not Have then
               Append
                 (Repo_Findings,
                  "(repo)" & HT & Image.Image (Count) &
                  " new paths claimed by no node, and no manifest to " &
                  "classify them against" & LF);
               return;
            end if;

            declare
               Matched : Lists.Vector;
               Text    : constant String := To_String (Manifest);
               Start   : Positive        := Text'First;
            begin
               for I in Text'First .. Text'Last + 1 loop
                  if I > Text'Last or else Text (I) = LF then
                     declare
                        Row : constant Build_Lists.Maybe_Row :=
                          Build_Lists.Parse_Row (Text (Start .. I - 1));
                     begin
                        if Row.Found then
                           declare
                              Hit : Unbounded_String;
                              Ok  : Boolean;
                              Cut : Positive := 1;
                           begin
                              Build_Lists.Select_Paths
                                (Env, To_String (Unclaimed),
                                 To_String (Row.Include),
                                 To_String (Row.Exclude), Hit, Ok);
                              if Ok then
                                 declare
                                    Whole : constant String := To_String (Hit);
                                 begin
                                    Cut := Whole'First;
                                    for K in Whole'First .. Whole'Last + 1 loop
                                       if K > Whole'Last or else Whole (K) = LF
                                       then
                                          if K > Cut then
                                             Matched.Append
                                               (To_Unbounded_String
                                                  (Whole (Cut .. K - 1)));
                                          end if;
                                          Cut := K + 1;
                                       end if;
                                    end loop;
                                 end;
                              end if;
                           end;
                        end if;
                     end;
                     Start := I + 1;
                  end if;
               end loop;

               --  The distinct paths that matched some pattern.
               declare
                  Set : Core.Text_Lists.Set;
               begin
                  for M of Matched loop
                     Set.Include (To_String (M));
                  end loop;
                  if Natural (Set.Length) > 0 then
                     Append
                       (Repo_Findings,
                        "(repo)" & HT & Image.Image (Natural (Set.Length)) &
                        " new paths already match a manifest pattern -- " &
                        "re-run `synapse build-lists` to claim them" & LF);
                  end if;

                  declare
                     Needs : Lists.Vector;
                     Whole : constant String := To_String (Unclaimed);
                     Cut   : Positive        := Whole'First;
                  begin
                     for K in Whole'First .. Whole'Last + 1 loop
                        if K > Whole'Last or else Whole (K) = LF then
                           if K > Cut
                             and then not Set.Contains (Whole (Cut .. K - 1))
                           then
                              Needs.Append
                                (To_Unbounded_String (Whole (Cut .. K - 1)));
                           end if;
                           Cut := K + 1;
                        end if;
                     end loop;
                     if Needs.Is_Empty then
                        return;
                     end if;
                     Append
                       (Repo_Findings,
                        "(repo)" & HT & Image.Image (Natural (Needs.Length)) &
                        " new paths match no manifest pattern: ");
                     --  `head -5 | tr '\n' ' '`: five names, space joined.
                     for I in 1 .. Natural'Min (5, Natural (Needs.Length)) loop
                        Append (Repo_Findings, To_String (Needs (I)) & " ");
                     end loop;
                     Append (Repo_Findings, "" & LF);
                  end;
               end;
            end;
         end;
      end;
   end Report_Added_Paths;

   function Cmd_Drift
     (Env : Environment; Ctx : Context.Context; Rest : Lists.Vector)
      return Exit_Code
   is
      Map           : Adapters.Index_Map.Map;
      Names         : Lists.Vector;
      Found         : Boolean;
      Repo_Findings : Unbounded_String;
      Node_Findings : Unbounded_String;
      Baselines     : Baseline_Vectors.Vector;
      Pairs         : Pairing_Vectors.Vector;
   begin
      if not Rest.Is_Empty then
         return Usage (Env);
      end if;
      if not Repo_Root_Present (Env, Ctx, "drift") then
         return 1;
      end if;
      Node_Names (Ctx, Map, Names, Found);
      if not Found then
         return 1;
      end if;

      for Node_File of Names loop
         declare
            Name : constant String := Context.Strip_Md (To_String (Node_File));
            Node : constant Context.Maybe_Text :=
              Context.Read_Node (Ctx, To_String (Node_File));
         begin
            if not Node.Found then
               Append
                 (Node_Findings,
                  Drift.Undiffable_Line (Name, Drift.Node_File_Missing));
            else
               declare
                  Recorded : constant Node_Query.Maybe_Text :=
                    Node_Query.Field (To_String (Node.Value), "commit");
                  Commit   : constant String                :=
                    (if Recorded.Found then To_String (Recorded.Value)
                     else "");
               begin
                  if Commit = "" then
                     Append
                       (Node_Findings,
                        Drift.Undiffable_Line
                          (Name, Drift.No_Commit_Recorded));
                  elsif not Commit_Exists (Env, Ctx, Commit) then
                     Append
                       (Node_Findings,
                        Drift.Undiffable_Line
                          (Name, Drift.Baseline_Absent, Commit));
                  else
                     declare
                        Base  : constant Positive :=
                          Baseline_For
                            (Env, Ctx, Baselines, Commit, Repo_Findings);
                        Paths : Lists.Vector      :=
                          Node_Query.Sources (To_String (Node.Value));
                     begin
                        Sorting.Sort (Paths);
                        Pairs.Append
                          (Pairing'
                             (Node => To_Unbounded_String (Name), Base => Base,
                              Paths => Paths));
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      for P of Pairs loop
         declare
            Changes : constant Drift.Node_Drift :=
              Drift.Of_Node (P.Paths, Baselines (P.Base).Changes);
         begin
            if Drift.Any (Changes) then
               Baselines (P.Base).Dirty := True;
            end if;
            Append
              (Node_Findings, Drift.Findings (To_String (P.Node), Changes));
         end;
      end loop;

      Report_Added_Paths (Env, Ctx, Map, Baselines, Repo_Findings);

      --  Silence is the signal: nothing found means the graph matches.
      if Length (Repo_Findings) = 0 and then Length (Node_Findings) = 0 then
         return 0;
      end if;

      --  Context is only worth printing next to a real finding.
      declare
         Upstream : constant String := Upstream_Name (Env, Ctx);
      begin
         if Upstream /= "" then
            declare
               Behind : constant Natural :=
                 Count_Of (Env, Ctx, "HEAD.." & Upstream);
            begin
               --  It never fetches, so this is the state as of the last
               --  fetch.
               if Behind > 0 then
                  Say
                    (Env,
                     "(repo)" & HT & Image.Image (Behind) &
                     " commits behind " & Upstream & ", as of the last fetch" &
                     LF);
               end if;
            end;
         end if;
      end;
      for B of Baselines loop
         --  Not when divergent: that line already reports both directions.
         if B.Dirty and then not B.Divergent then
            declare
               Commit : constant String  := To_String (B.Commit);
               N : constant Natural := Count_Of (Env, Ctx, Commit & "..HEAD");
            begin
               if N > 0 then
                  Say
                    (Env,
                     "(repo)" & HT & Image.Image (N) &
                     " commits since baseline " & Drift.Short_Commit (Commit) &
                     LF);
               end if;
            end;
         end if;
      end loop;
      Say (Env, To_String (Repo_Findings));
      Say (Env, To_String (Node_Findings));
      return 0;
   end Cmd_Drift;

   ---------------------------------------------------------------------------
   --  grounding
   ---------------------------------------------------------------------------

   function Cmd_Grounding
     (Env : Environment; Ctx : Context.Context; Rest : Lists.Vector)
      return Exit_Code
   is
      Root : constant String := To_String (Ctx.Repo_Root);
   begin
      if Natural (Rest.Length) = 2 and then To_String (Rest (2)) = "--list"
      then
         --  The node is checked first, so a typo does not read as having no
         --  groundings.
         declare
            Node : constant Context.Maybe_Text :=
              Need (Ctx, To_String (Rest (1)));
         begin
            if not Node.Found then
               return 1;
            end if;
            for G of Verify.Groundings (To_String (Node.Value)) loop
               Say (Env, To_String (G.Path) & HT & To_String (G.Lines) & LF);
            end loop;
            return 0;
         end;
      end if;
      if not Rest.Is_Empty then
         return Usage (Env);
      end if;
      if not Repo_Root_Present (Env, Ctx, "grounding") then
         return 1;
      end if;

      for File of Context.Node_Files (Ctx) loop
         declare
            Node : constant Context.Maybe_Text :=
              Context.Read_Node (Ctx, To_String (File));
         begin
            if Node.Found then
               declare
                  Name : constant String :=
                    Context.Strip_Md (To_String (File));
               begin
                  for G of Verify.Groundings (To_String (Node.Value)) loop
                     declare
                        Content : Unbounded_String;
                        Have    : Boolean;
                        Path    : constant String := To_String (G.Path);
                        Lines   : constant String := To_String (G.Lines);
                     begin
                        Support.Read_Repo_File (Root, Path, Content, Have);
                        if not Have then
                           Say
                             (Env,
                              Name & HT & "grounding file gone: " & Path & LF);
                        else
                           declare
                              Range_Of : constant Verify.Maybe_Range :=
                                Verify.Range_Of (G);
                              Whole : constant String := To_String (Content);
                           begin
                              if Range_Of.Found then
                                 declare
                                    Bounds :
                                      constant Core.Line_Slice.Maybe_Bounds :=
                                      Core.Line_Slice.Bounds
                                        (Whole, Range_Of.Value.First,
                                         Range_Of.Value.Last);
                                    Match  : constant Boolean :=
                                      Bounds.Found
                                      and then
                                        Core.Hashing.Sha256_Hex
                                          (Whole
                                             (Bounds.Value.From ..
                                                  Bounds.Value.To)) =
                                        To_String (G.Digest);
                                 begin
                                    if not Match then
                                       --  A pure line shift, an insertion
                                       --  above the range, is re-pointed and
                                       --  not called broken.
                                       declare
                                          Span  : constant Natural :=
                                            Range_Of.Value.Last -
                                            Range_Of.Value.First + 1;
                                          Moved :
                                            constant Verify.Maybe_Range :=
                                            Verify.Find_Moved
                                              (Whole, Span,
                                               To_String (G.Digest));
                                       begin
                                          if Moved.Found then
                                             Say
                                               (Env,
                                                Name & HT &
                                                "grounding moved: " & Path &
                                                " " & Lines & " -> " &
                                                Image.Image
                                                  (Moved.Value.First) &
                                                "-" &
                                                Image.Image
                                                  (Moved.Value.Last) &
                                                " (re-point, no reading " &
                                                "needed)" & LF);
                                          else
                                             Say
                                               (Env,
                                                Name & HT &
                                                "grounding changed: " & Path &
                                                " " & Lines &
                                                " (re-check the claim " &
                                                "resting on it)" & LF);
                                          end if;
                                       end;
                                    end if;
                                 end;
                              end if;
                           end;
                        end if;
                     end;
                  end loop;
               end;
            end if;
         end;
      end loop;
      return 0;
   end Cmd_Grounding;

   ---------------------------------------------------------------------------
   --  links
   ---------------------------------------------------------------------------

   type Edge_Row is record
      Source, Relation, Target : Unbounded_String;
   end record;

   package Edge_Row_Vectors is new Ada.Containers.Vectors (Positive, Edge_Row);

   type Pair is record
      First, Second : Unbounded_String;
   end record;

   function Pair_Before (Left, Right : Pair) return Boolean is
     (Left.First < Right.First
      or else (Left.First = Right.First and then Left.Second < Right.Second));

   package Pair_Vectors is new Ada.Containers.Vectors (Positive, Pair);

   package Pair_Sorting is new Pair_Vectors.Generic_Sorting (Pair_Before);

   procedure Print_Pairs (Env : Environment; Rows : in out Pair_Vectors.Vector)
   is
   begin
      Pair_Sorting.Sort (Rows);
      for R of Rows loop
         Say (Env, To_String (R.First) & HT & To_String (R.Second) & LF);
      end loop;
   end Print_Pairs;

   --  `source`, `relation`, `target` of every link of the namespace.
   procedure Build_Graph
     (Ctx   :     Context.Context; Names : out Lists.Vector;
      Edges : out Edge_Row_Vectors.Vector)
   is
   begin
      for File of Context.Node_Files (Ctx) loop
         declare
            Node : constant Context.Maybe_Text :=
              Context.Read_Node (Ctx, To_String (File));
         begin
            if Node.Found then
               --  The file name without `.md`: what a wikilink resolves
               --  against.
               declare
                  Name : constant Unbounded_String :=
                    To_Unbounded_String (Context.Strip_Md (To_String (File)));
               begin
                  Names.Append (Name);
                  for E of Node_Query.Edges (To_String (Node.Value)) loop
                     Edges.Append
                       (Edge_Row'
                          (Source => Name, Relation => E.Relation,
                           Target => E.Target));
                  end loop;
               end;
            end if;
         end;
      end loop;
   end Build_Graph;

   function Cmd_Links
     (Env : Environment; Ctx : Context.Context; Rest : Lists.Vector)
      return Exit_Code
   is
   begin
      if Rest.Is_Empty then
         return Usage (Env);
      end if;
      declare
         First : constant String := To_String (Rest (1));
      begin
         if First = "--check" then
            if Natural (Rest.Length) /= 1 then
               return Usage (Env);
            end if;
            declare
               Names : Lists.Vector;
               Edges : Edge_Row_Vectors.Vector;
            begin
               Build_Graph (Ctx, Names, Edges);
               --  A broken wikilink renders as plain text, and nothing else
               --  notices it.
               for E of Edges loop
                  if not Names.Contains (E.Target) then
                     Say
                       (Env,
                        To_String (E.Source) & HT & To_String (E.Relation) &
                        " -> " & To_String (E.Target) & " (no such node)" &
                        LF);
                  end if;
               end loop;
               return 0;
            end;
         end if;
         if First'Length = 0 or else First (First'First) = '-' then
            return Usage (Env);
         end if;

         declare
            Node_Name : constant String := Context.Strip_Md (First);
            Node      : constant Context.Maybe_Text := Need (Ctx, First);
         begin
            if not Node.Found then
               return 1;
            end if;
            if Natural (Rest.Length) = 1 then
               --  One read: deriving the whole graph to filter one node is
               --  many reads to answer one.
               declare
                  Rows : Pair_Vectors.Vector;
               begin
                  for E of Node_Query.Edges (To_String (Node.Value)) loop
                     Rows.Append
                       (Pair'(First => E.Relation, Second => E.Target));
                  end loop;
                  Print_Pairs (Env, Rows);
                  return 0;
               end;
            end if;
            if Natural (Rest.Length) /= 2 then
               return Usage (Env);
            end if;

            declare
               Flag  : constant String := To_String (Rest (2));
               Names : Lists.Vector;
               Edges : Edge_Row_Vectors.Vector;
            begin
               if Flag = "--inbound" then
                  Build_Graph (Ctx, Names, Edges);
                  declare
                     Rows : Pair_Vectors.Vector;
                  begin
                     for E of Edges loop
                        if To_String (E.Target) = Node_Name then
                           Rows.Append
                             (Pair'(First => E.Relation, Second => E.Source));
                        end if;
                     end loop;
                     Print_Pairs (Env, Rows);
                     return 0;
                  end;
               elsif Flag = "--closure" then
                  Build_Graph (Ctx, Names, Edges);
                  declare
                     --  Breadth first, so the depth is the shortest hop count
                     --  and a cycle ends.
                     Seen   : Core.Text_Lists.Set;
                     Queue  : Lists.Vector;
                     Depth  :
                       array (1 .. Natural (Edges.Length) + 1) of Natural :=
                       [others => 0];
                     Rows   : Pair_Vectors.Vector;
                     Cursor : Positive := 1;
                     Levels : Lists.Vector;
                  begin
                     Seen.Include (Node_Name);
                     Queue.Append (To_Unbounded_String (Node_Name));
                     Levels.Append (To_Unbounded_String ("0"));
                     while Cursor <= Natural (Queue.Length) loop
                        declare
                           Current : constant String  :=
                             To_String (Queue (Cursor));
                           Here    : constant Natural :=
                             Natural'Value (To_String (Levels (Cursor)));
                        begin
                           for E of Edges loop
                              if To_String (E.Source) = Current
                                and then Length (E.Target) /= 0
                                and then not Seen.Contains
                                  (To_String (E.Target))
                              then
                                 Seen.Include (To_String (E.Target));
                                 Queue.Append (E.Target);
                                 Levels.Append
                                   (To_Unbounded_String
                                      (Image.Image (Here + 1)));
                                 Rows.Append
                                   (Pair'
                                      (First  =>
                                         To_Unbounded_String
                                           ([
                                            1 ..
                                                9 -
                                                Image.Image (Here + 1)'
                                                  Length =>
                                              '0'] &
                                            Image.Image (Here + 1)),
                                       Second => E.Target));
                              end if;
                           end loop;
                        end;
                        Cursor := Cursor + 1;
                     end loop;
                     pragma Unreferenced (Depth);
                     --  `sort -k1,1n -k2,2`: depth as a number, then the
                     --  name; the depth is padded so a text order is one.
                     Pair_Sorting.Sort (Rows);
                     for R of Rows loop
                        Say
                          (Env,
                           Image.Image (Natural'Value (To_String (R.First))) &
                           HT & To_String (R.Second) & LF);
                     end loop;
                     return 0;
                  end;
               end if;
               return Usage (Env);
            end;
         end;
      end;
   end Cmd_Links;

   ---------------------------------------------------------------------------
   --  symbol
   ---------------------------------------------------------------------------

   function Cmd_Symbol
     (Env : Environment; Ctx : Context.Context; Rest : Lists.Vector)
      return Exit_Code
   is
      Root : constant String := To_String (Ctx.Repo_Root);
   begin
      --  Disabled: no cache I/O and no tagging, as the prompt hook's own
      --  setting says.
      if Env.Vars.Get ("SYNAPSE_DISABLE_SYMBOL_CACHE").Found then
         return 0;
      end if;
      if Natural (Rest.Length) = 1 and then not Is_Blank (Rest (1)) then
         --  The node is what a session reaching for `symbol` first usually
         --  lacks.
         Complain
           (Env,
            Prog & ": symbol needs a node; without one, `synapse callers " &
            To_String (Rest (1)) & " --all` lists every definition and " &
            "reference repo-wide" & LF);
         return 2;
      end if;
      if Natural (Rest.Length) /= 2 or else Is_Blank (Rest (1))
        or else Is_Blank (Rest (2))
      then
         return Usage (Env);
      end if;
      if not Repo_Root_Present (Env, Ctx, "symbol") then
         return 1;
      end if;
      declare
         Name     : constant String             := To_String (Rest (1));
         Node_Arg : constant String             := To_String (Rest (2));
         Node     : constant Context.Maybe_Text := Need (Ctx, Node_Arg);
      begin
         if not Node.Found then
            return 1;
         end if;
         declare
            Paths     : constant Lists.Vector :=
              Node_Query.Sources (To_String (Node.Value));
            Requested : Cache_Adapter.Path_Hash_Vectors.Vector;
         begin
            if Paths.Is_Empty then
               return 0;
            end if;
            --  Every source hashed, then the cache backfilled: the hashes
            --  are needed here anyway.
            for P of Paths loop
               declare
                  Content : Unbounded_String;
                  Have    : Boolean;
               begin
                  Support.Read_Repo_File (Root, To_String (P), Content, Have);
                  if not Have then
                     Complain
                       (Env,
                        Prog & ": could not hash '" & Node_Arg & "' sources" &
                        LF);
                     return 1;
                  end if;
                  Requested.Append
                    (Cache_Adapter.Path_Hash'
                       (Path   => P,
                          Hash => Core.Hashing.Blob_Hash (To_String (Content))));
               end;
            end loop;

            declare
               Cache_Path : constant String :=
                 To_String (Ctx.Work_Dir) & "/_tags_cache.bin";
               Cache      : Cache_Adapter.Cache;
            begin
               Cache_Adapter.Open (Cache, Cache_Path);
               if Cache_Adapter.Discarded (Cache) /= Cache_Adapter.None then
                  Complain
                    (Env,
                     Prog & ": unreadable tags cache: " & Cache_Path & LF);
                  return 0;
               end if;
               --  Not fatal: still worth answering from what is cached.
               if not Tags_Cache.Backfill (Env, Root, Cache, Requested) then
                  Complain
                    (Env,
                     Prog & ": symbol cache backfill failed for '" & Node_Arg &
                     "' -- continuing with what's already cached" & LF);
               end if;

               for P of Paths loop
                  declare
                     Path     : constant String := To_String (P);
                     Entry_Of : constant Cache_Adapter.Maybe_Value :=
                       Cache_Adapter.Get (Cache, Path);
                     Outcome  : constant Core.Symbol.Outcome       :=
                       Core.Symbol.Outcome_For
                         (Entry_Of.Found,
                          Entry_Of.Found and then Entry_Of.Value.Unsupported,
                          (if Entry_Of.Found then
                             To_String (Entry_Of.Value.Tags)
                           else ""));
                  begin
                     case Outcome.Kind is
                        when Core.Symbol.Not_Cached =>
                           Complain
                             (Env,
                              Prog & ": " & Path &
                              " not checked (no cache entry)" & LF);

                        when Core.Symbol.Unsupported =>
                           Complain
                             (Env,
                              Prog & ": " & Path &
                              " not checked (unsupported: no grammar, " &
                              "tree-sitter, or C compiler)" & LF);

                        when Core.Symbol.Checked =>
                           for Tag of Core.Symbol.Matches
                             (To_String (Outcome.Tags), Name)
                           loop
                              Say (Env, Core.Tag_Line.Refs_Row (Path, Tag));
                           end loop;
                     end case;
                  end;
               end loop;
               return 0;
            end;
         end;
      end;
   end Cmd_Symbol;

   ---------------------------------------------------------------------------
   --  Dispatch
   ---------------------------------------------------------------------------

   function Dispatch
     (Env  : Environment; Ctx : Context.Context; Sub : String;
      Rest : Lists.Vector) return Exit_Code
   is
   begin
      if Sub = "body" then
         return Cmd_Body (Env, Ctx, Rest);
      elsif Sub = "sources" then
         return Cmd_Sources (Env, Ctx, Rest);
      elsif Sub = "field" then
         return Cmd_Field (Env, Ctx, Rest);
      elsif Sub = "stale" then
         return Cmd_Stale (Env, Ctx, Rest);
      elsif Sub = "drift" then
         return Cmd_Drift (Env, Ctx, Rest);
      elsif Sub = "grounding" then
         return Cmd_Grounding (Env, Ctx, Rest);
      elsif Sub = "links" then
         return Cmd_Links (Env, Ctx, Rest);
      else
         return Cmd_Symbol (Env, Ctx, Rest);
      end if;
   end Dispatch;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Index    : Positive := 1;
      Explicit : Unbounded_String;
      Have_Ns  : Boolean  := False;
   begin
      if Args.Is_Empty then
         return Usage (Env);
      end if;
      if To_String (Args (Index)) = "--namespace" then
         if Natural (Args.Length) < 3 then
            return Usage (Env);
         end if;
         Explicit := Args (2);
         Have_Ns  := True;
         Index    := 3;
      end if;
      declare
         Sub : constant String := To_String (Args (Index));
      begin
         if Cli_Args.Is_Help (Sub) then
            Complain (Env, Usage_Text);
            return 0;
         end if;
         --  Checked before the environment: a mistyped subcommand should not
         --  read as a missing vault.
         if Sub not in
             "body" | "sources" | "field" | "stale" | "drift" | "grounding"
             | "links" | "symbol"
         then
            return Usage (Env);
         end if;

         declare
            Rest : Lists.Vector;
         begin
            for I in Index + 1 .. Natural (Args.Length) loop
               Rest.Append (Args (I));
            end loop;

            --  `field --file` names its own file and not a vault node, for a
            --  draft that has no title yet.
            if Sub = "field" and then not Rest.Is_Empty
              and then To_String (Rest (1)) = "--file"
            then
               if Natural (Rest.Length) /= 3 or else Is_Blank (Rest (2))
                 or else Is_Blank (Rest (3))
               then
                  return Usage (Env);
               end if;
               return
                 Field_Of_File
                   (Env, To_String (Rest (2)), To_String (Rest (3)));
            end if;

            declare
               Found : constant Context.Maybe_Context :=
                 (if Have_Ns then
                    Context.Resolve_Explicit (Env, Prog, To_String (Explicit))
                  else Context.Resolve (Env, Prog));
            begin
               if not Found.Found then
                  return 1;
               end if;
               if not Context.Verify_Namespace (Env, Found.Value, Prog) then
                  return 1;
               end if;
               return Dispatch (Env, Found.Value, Sub, Rest);
            end;
         end;
      end;
   end Run;

end Synapse.Commands.Query;
