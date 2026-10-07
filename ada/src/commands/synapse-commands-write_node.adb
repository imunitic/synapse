with Ada.Directories;
with Ada.Strings.Fixed;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.System_Spawner;
with Synapse.Adapters.Tags_Cache;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;
with Synapse.Commands.Tags_Cache;
with Synapse.Commands.Vault_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Emit;
with Synapse.Core.Fence_Languages;
with Synapse.Core.Graph_Model;
with Synapse.Core.Hashing;
with Synapse.Core.Line_Slice;
with Synapse.Core.Node_Format;
with Synapse.Core.Node_Query;
with Synapse.Core.Timestamps;
with Synapse.Ports.Variables;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Store;

package body Synapse.Commands.Write_Node is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;
   package Vault renames Synapse.Commands.Vault_Support;
   package Emit renames Synapse.Core.Emit;
   package Runner renames Synapse.Ports.Process_Runner;
   package Port renames Synapse.Ports.Store;
   package Image renames Synapse.Core.Decimal_Image;

   use type Emit.Problem_Kind;
   use type Emit.Span_Kind;
   use type Ada.Directories.File_Kind;

   Prog : constant String    := "synapse-write-node";
   LF   : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse write-node --title <t> --summary <s> --paths <file> " &
     "--body <file>" & LF & LF &
     "  --title    node title. Used verbatim as the H1, and sanitized for " &
     "the filename." & LF &
     "  --summary  one line for the index bullet, stored as the `summary` " &
     "field." & LF &
     "  --paths    file of repo-relative paths, one per line: every file " &
     "the node covers." & LF &
     "  --body     file holding the authored prose (## Summary / ## Crux / " &
     "## Links)." & LF;

   Largest_File : constant := 256 * 1_024 * 1_024;

   type Text_Vector is array (Positive range <>) of Unbounded_String;

   --  The lines of Text, without carriage returns or blank ones, in byte
   --  order and without repeats: `LC_ALL=C sort -u`.
   function Sorted_Unique (Text : String) return Lists.Vector is
      Found : Lists.Vector;
      Start : Positive := Text'First;

      function Before (Left, Right : Unbounded_String) return Boolean is
        (Left < Right);

      package Sorting is new Lists.Vectors.Generic_Sorting (Before);
   begin
      for I in Text'First .. Text'Last + 1 loop
         if I > Text'Last or else Text (I) = LF then
            declare
               Last : Natural := I - 1;
            begin
               if Last >= Start and then Text (Last) = ASCII.CR then
                  Last := Last - 1;
               end if;
               if Last >= Start then
                  Found.Append (To_Unbounded_String (Text (Start .. Last)));
               end if;
            end;
            Start := I + 1;
         end if;
      end loop;
      Sorting.Sort (Found);
      declare
         Result : Lists.Vector;
      begin
         for Item of Found loop
            if Result.Is_Empty or else Result.Last_Element /= Item then
               Result.Append (Item);
            end if;
         end loop;
         return Result;
      end;
   end Sorted_Unique;

   --  git's answer on standard output, trimmed, when it succeeded.
   procedure Git
     (Env    :     Environment; Root : String; Args : Lists.Vector;
      Output : out Unbounded_String; Ok : out Boolean)
   is
      Options : Runner.Options;
   begin
      Options.Cwd := To_Unbounded_String (Root);
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

   function Trimmed (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last
        and then Text (First) in ' ' | ASCII.HT | ASCII.CR | LF
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then Text (Last) in ' ' | ASCII.HT | ASCII.CR | LF
      loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   function Words (A1, A2, A3, A4 : String := "") return Lists.Vector is
      Result : Lists.Vector;
   begin
      for Word in 1 .. 4 loop
         declare
            Text : constant String :=
              (case Word is when 1 => A1, when 2 => A2, when 3 => A3,
                 when others => A4);
         begin
            if Text /= "" then
               Result.Append (To_Unbounded_String (Text));
            end if;
         end;
      end loop;
      return Result;
   end Words;

   --  `git rev-parse --verify --quiet HEAD`: `--verify`, since without it a
   --  failure still echoes the string `HEAD`.
   function Head_Commit (Env : Environment; Root : String) return String is
      Args   : Lists.Vector;
      Output : Unbounded_String;
      Ok     : Boolean;
   begin
      Args := Words ("rev-parse", "--verify", "--quiet", "HEAD");
      Git (Env, Root, Args, Output, Ok);
      return (if Ok then Trimmed (To_String (Output)) else "");
   end Head_Commit;

   --  The hashes come from the worktree, so a dirty source makes the recorded
   --  commit approximate. Scoped to this node's own paths.
   procedure Warn_Dirty_Sources
     (Env : Environment; Root : String; Paths : Lists.Vector; Commit : String)
   is
      Args   : Lists.Vector;
      Output : Unbounded_String;
      Ok     : Boolean;
      Named  : Natural := 0;
      Names  : Unbounded_String;
   begin
      Args := Words ("diff", "--name-only", "HEAD");
      Git (Env, Root, Args, Output, Ok);
      if not Ok then
         return;
      end if;
      declare
         Text  : constant String := To_String (Output);
         Start : Positive        := Text'First;
      begin
         for I in Text'First .. Text'Last + 1 loop
            if I > Text'Last or else Text (I) = LF then
               if I > Start and then Named < 3 then
                  declare
                     Line : constant String := Text (Start .. I - 1);
                  begin
                     for P of Paths loop
                        if To_String (P) = Line then
                           Append (Names, Line & " ");
                           Named := Named + 1;
                           exit;
                        end if;
                     end loop;
                  end;
               end if;
               Start := I + 1;
            end if;
         end loop;
      end;
      if Named = 0 then
         return;
      end if;
      Complain
        (Env,
         Prog & ": NOTE uncommitted changes in this node's sources: " &
         Trimmed (To_String (Names)) & LF & "  commit: " & Commit &
         " records what was checked out, not a faithful drift baseline" & LF);
   end Warn_Dirty_Sources;

   --  True when the span is unusable, having said why.
   function Span_Problem
     (Env   : Environment; Span : Emit.Span; Kind : Emit.Span_Kind;
      Paths : Lists.Vector; Content : Unbounded_String; Present : Boolean)
      return Boolean
   is
      Label : constant String := Emit.Keyword (Kind);
      Path  : constant String := To_String (Span.Path);
   begin
      if not Present then
         Complain
           (Env, Prog & ": " & Label & " path does not exist: " & Path & LF);
         return True;
      end if;
      declare
         Total   : constant Natural           :=
           Core.Line_Slice.Count_Lines (To_String (Content));
         Problem : constant Emit.Span_Problem :=
           Emit.Check_Span (Span, Kind, Paths, Total);
      begin
         case Problem.Kind is
            when Emit.None =>
               return False;

            when Emit.Not_Claimed =>
               Complain
                 (Env,
                  Prog & ": " & Label & " path is not in this node's " &
                  "sources: " & Path & LF);

            when Emit.Out_Of_Range =>
               Complain
                 (Env,
                  Prog & ": " & Label & " range " & Image.Image (Span.First) &
                  "-" & Image.Image (Span.Last) & " outside " & Path & " (1-" &
                  Image.Image (Problem.Total_Lines) & ")" & LF);

            when Emit.Too_Long =>
               Complain
                 (Env,
                  Prog & ": " & Label & " range " & Image.Image (Span.First) &
                  "-" & Image.Image (Span.Last) & " is " &
                  Image.Image (Problem.Line_Count) & " lines; keep it under " &
                  Image.Image (Emit.Cap (Kind)) & LF);
               if Kind = Emit.Crux then
                  Complain
                    (Env,
                     "  a crux is the few lines carrying the decision, not " &
                     "the whole function" & LF);
               end if;
         end case;
         return True;
      end;
   end Span_Problem;

   --  Keeps the tags cache current for the node's sources, as a byproduct, so
   --  `query symbol` is a cache read. Never fatal.
   procedure Refresh_Tags_Cache
     (Env      : Environment; Ctx : Context.Context; Paths : Lists.Vector;
      Contents : Text_Vector)
   is
      Cache     : Adapters.Tags_Cache.Cache;
      Requested : Adapters.Tags_Cache.Path_Hash_Vectors.Vector;
   begin
      for I in Contents'Range loop
         Requested.Append
           (Adapters.Tags_Cache.Path_Hash'
              (Path => Paths (I),
               Hash => Core.Hashing.Blob_Hash (To_String (Contents (I)))));
      end loop;
      Adapters.Tags_Cache.Open
        (Cache, To_String (Ctx.Work_Dir) & "/_tags_cache.bin");
      if not Tags_Cache.Backfill
          (Env, To_String (Ctx.Repo_Root), Cache, Requested)
      then
         Complain (Env, Prog & ": tags cache refresh failed (non-fatal)" & LF);
      end if;
   exception
      when others =>
         Complain (Env, Prog & ": tags cache refresh failed (non-fatal)" & LF);
   end Refresh_Tags_Cache;

   function Pad3 (N : Natural) return String is
      Text : constant String := Image.Image (N);
   begin
      return
        (if Text'Length >= 3 then Text
         else [1 .. 3 - Text'Length => '0'] & Text);
   end Pad3;

   --  The fence languages registry: the file `SYNAPSE_FENCE_LANGUAGES_CONF`
   --  names, else the configuration tiers, else the home's `.claude`. A file
   --  that is not there is an empty registry.
   procedure Load_Fence_Languages
     (Env      :     Environment; Home : String;
      Registry : out Core.Fence_Languages.Registry; Ok : out Boolean)
   is
      Named : constant Ports.Variables.Maybe_Value :=
        Env.Vars.Get ("SYNAPSE_FENCE_LANGUAGES_CONF");
      Found : constant Support.Maybe_Path          :=
        Adapters.Conf_Files.Resolve_Conf_Path
          (Env.Vars.all, "synapse-fence-languages.conf");
      Path  : constant String                      :=
        (if Named.Found then To_String (Named.Value)
         elsif Found.Found then To_String (Found.Value)
         else Home & "/.claude/synapse-fence-languages.conf");
      Text  : Unbounded_String;
      Read  : Boolean;
   begin
      Ok := True;
      if not Ada.Directories.Exists (Path) then
         return;
      end if;
      Support.Read_File (Path, 1_024 * 1_024, Text, Read);
      if not Read then
         Ok := False;
         return;
      end if;
      Registry := Core.Fence_Languages.Parse (To_String (Text));
   exception
      when Core.Fence_Languages.Malformed =>
         Ok := False;
   end Load_Fence_Languages;

   --  The slice of Content a span names, which Check_Span has already
   --  shown to exist.
   function Sliced (Content : String; Span : Emit.Span) return String is
      Bounds : constant Core.Line_Slice.Maybe_Bounds :=
        Core.Line_Slice.Bounds (Content, Span.First, Span.Last);
   begin
      return Content (Bounds.Value.From .. Bounds.Value.To);
   end Sliced;

   function Finish
     (Env       : Environment; Ctx : Context.Context; Item : Input;
      Paths : Lists.Vector; Sources : Core.Graph_Model.Source_Vectors.Vector;
      Digest    : String; Commit : String; Tail : Unbounded_String;
      Node_File : String; Line : out Unbounded_String) return Exit_Code
   is
      Root     : constant String := To_String (Ctx.Repo_Root);
      Home     : constant Ports.Variables.Maybe_Value := Env.Vars.Get ("HOME");
      Fence    : Core.Fence_Languages.Registry;
      Fence_Ok : Boolean;
      Prose    : Unbounded_String                     := Item.Body_Text;
      Note     : Emit.Note;
   begin
      if not Home.Found then
         return 1;
      end if;
      Load_Fence_Languages (Env, To_String (Home.Value), Fence, Fence_Ok);
      if not Fence_Ok then
         Complain
           (Env, Prog & ": cannot read the fence-languages registry" & LF);
         return 1;
      end if;

      --  The crux directive is looked for in the `## Crux` section alone:
      --  prose that describes the syntax elsewhere would otherwise be taken
      --  for the real one. No section means no crux was authored.
      declare
         Section   : constant Emit.Maybe_Text :=
           Emit.Section (To_String (Prose), "Crux");
         Directive : constant Emit.Maybe_Text :=
           (if Section.Found then
              Emit.Find_Directive (To_String (Section.Value), Emit.Kind_Crux)
            else (Found => False));
      begin
         if Directive.Found then
            declare
               Text  : constant String          := To_String (Directive.Value);
               Arg   : constant Emit.Maybe_Text :=
                 Emit.Directive_Arg
                   (Text (Text'First + 4 .. Text'Last - 3), Emit.Kind_Crux);
               Block : Unbounded_String;
            begin
               if not Arg.Found then
                  Complain (Env, Prog & ": bad crux directive: " & Text & LF);
                  return 1;
               end if;
               if To_String (Arg.Value) = "none" then
                  Block := To_Unbounded_String (Emit.Crux_None_Text);
               else
                  declare
                     Span : constant Emit.Maybe_Span :=
                       Emit.Parse_Span (To_String (Arg.Value));
                  begin
                     if not Span.Found then
                        Complain
                          (Env,
                           Prog & ": bad crux directive: " & Text & LF &
                           "  expected: <!-- crux: path/to/file.ext 412-419 " &
                           "-->  (or 'none')" & LF);
                        return 1;
                     end if;
                     declare
                        Content : Unbounded_String;
                        Present : Boolean;
                     begin
                        Support.Read_Repo_File
                          (Root, To_String (Span.Value.Path), Content,
                           Present);
                        if Span_Problem
                            (Env, Span.Value, Emit.Crux, Paths, Content,
                             Present)
                        then
                           return 1;
                        end if;
                        Block         :=
                          To_Unbounded_String
                            (Emit.Crux_Block
                               (Span.Value,
                                Sliced (To_String (Content), Span.Value),
                                Core.Fence_Languages.Language_For
                                  (Fence, To_String (Span.Value.Path))));
                        Note.Has_Crux := True;
                        Note.Crux     :=
                          (Path  => Span.Value.Path,
                           Lines =>
                             To_Unbounded_String
                               (Image.Image (Span.Value.First) & "-" &
                                Image.Image (Span.Value.Last)));
                     end;
                  end;
               end if;
               Prose :=
                 To_Unbounded_String
                   (Emit.Substitute_Line
                      (To_String (Prose), Text, To_String (Block)));
            end;
         end if;
      end;

      --  The groundings, recorded and then stripped from the prose.
      declare
         Found : constant Lists.Vector :=
           Emit.Directives (To_String (Prose), Emit.Kind_Grounded);
      begin
         for Directive of Found loop
            declare
               Text : constant String          := To_String (Directive);
               Arg  : constant Emit.Maybe_Text :=
                 Emit.Directive_Arg
                   (Text (Text'First + 4 .. Text'Last - 3),
                    Emit.Kind_Grounded);
            begin
               if not Arg.Found then
                  Complain
                    (Env, Prog & ": bad grounded_in directive: " & Text & LF);
                  return 1;
               end if;
               declare
                  Span : constant Emit.Maybe_Span :=
                    Emit.Parse_Span (To_String (Arg.Value));
               begin
                  if not Span.Found then
                     Complain
                       (Env,
                        Prog & ": bad grounded_in directive: " & Text & LF &
                        "  expected: <!-- grounded_in: path/to/file.ext " &
                        "10-14 -->" & LF);
                     return 1;
                  end if;
                  declare
                     Content : Unbounded_String;
                     Present : Boolean;
                  begin
                     Support.Read_Repo_File
                       (Root, To_String (Span.Value.Path), Content, Present);
                     if Span_Problem
                         (Env, Span.Value, Emit.Grounded, Paths, Content,
                          Present)
                     then
                        return 1;
                     end if;
                     Note.Grounded.Append
                       (Emit.Grounded_Row'
                          (Path   => Span.Value.Path,
                           Lines  =>
                             To_Unbounded_String
                               (Image.Image (Span.Value.First) & "-" &
                                Image.Image (Span.Value.Last)),
                           --  A digest of the slice and not the slice: the
                           --  field stays small, and a change elsewhere in
                           --  the file leaves it intact.
                           Digest =>
                             To_Unbounded_String
                               (Core.Hashing.Sha256_Hex
                                  (Sliced
                                     (To_String (Content), Span.Value)))));
                  end;
               end;
            end;
         end loop;
         if not Found.Is_Empty then
            Prose :=
              To_Unbounded_String (Emit.Strip_Grounded (To_String (Prose)));
         end if;
      end;

      declare
         Namespace : constant String  := To_String (Ctx.Namespace);
         At_Sign   : constant Natural :=
           Ada.Strings.Fixed.Index (Namespace, "@");
      begin
         Note.Title    := Item.Title;
         Note.Summary  := Item.Summary;
         Note.Project  :=
           To_Unbounded_String
             (if At_Sign = 0 then Namespace
              else Namespace (Namespace'First .. At_Sign - 1));
         Note.Branch   := Ctx.Branch;
         Note.Sources  := Sources;
         Note.Digest   := To_Unbounded_String (Digest);
         Note.Built_At :=
           To_Unbounded_String
             (Core.Timestamps.Built_At (Env.Clock.Timestamp));
         Note.Commit   := To_Unbounded_String (Commit);
         Note.Modules  := Core.Node_Query.Module_Counts (Paths, Ctx.Chains);
         Note.Prose    := Prose;
         Note.Tail     := Tail;
      end;

      --  PUT into the vault.
      declare
         Stack   : Vault.Store_Resolve.Stack;
         Ok      : Boolean;
         Spawner : aliased Adapters.System_Spawner.System_Spawner :=
           (Program => Env.Argv0);
      begin
         Vault.Open
           (Env, Prog, To_String (Ctx.Vault), Stack, Ok, Spawner'Access);
         if not Ok then
            return 1;
         end if;
         declare
            Wrote : constant Port.Write_Result :=
              Vault.Store_Resolve.Store (Stack).Write
                (To_String (Ctx.Dir) & "/" & Node_File, Emit.Image (Note));
         begin
            if not Wrote.Accepted then
               Complain
                 (Env,
                  Prog & ": write rejected (" & Pad3 (Wrote.Status) & "): " &
                  To_String (Wrote.Body_Text) & LF);
               return 1;
            end if;
         end;
      exception
         when Port.Store_Failure | Port.Unsafe_Node | Port.Node_Not_Found =>
            Complain (Env, Prog & ": write failed" & LF);
            return 1;
      end;

      Line :=
        To_Unbounded_String
          (Node_File & ASCII.HT & Image.Image (Natural (Paths.Length)) &
           " files" & ASCII.HT & Digest & LF);
      return 0;
   end Finish;

   function Write
     (Env  :     Environment; Ctx : Context.Context; Item : Input;
      Line : out Unbounded_String) return Exit_Code
   is
      Root       : constant String := To_String (Ctx.Repo_Root);
      Dir        : constant String := To_String (Ctx.Dir);
      Abs_Dir    : constant String := To_String (Ctx.Abs_Dir);
      Title      : constant String := To_String (Item.Title);
      Index_Text : Unbounded_String;
      Have_Index : Boolean;
   begin
      Line := Null_Unbounded_String;

      --  Refuse to write into another repository's namespace; an index that
      --  is not there yet means a first build.
      Support.Read_File
        (Abs_Dir & "/Index.md", Largest_File, Index_Text, Have_Index);
      if Have_Index then
         declare
            Remote          : constant Core.Node_Query.Maybe_Text :=
              Core.Node_Query.Field (To_String (Index_Text), "remote");
            Branch          : constant Core.Node_Query.Maybe_Text :=
              Core.Node_Query.Field (To_String (Index_Text), "branch");
            Existing_Remote : constant String                     :=
              (if Remote.Found then To_String (Remote.Value) else "");
            Existing_Branch : constant String                     :=
              (if Branch.Found then To_String (Branch.Value) else "");
         begin
            if Existing_Remote /= ""
              and then Existing_Remote /= To_String (Ctx.Remote)
            then
               Complain
                 (Env,
                  Prog & ": " & Dir & "/ belongs to a different repo" & LF &
                  "  existing remote: " & Existing_Remote & LF &
                  "  this repo:       " & To_String (Ctx.Remote) & LF &
                  "  refusing to overwrite -- rename one of the two repos " &
                  "first" & LF);
               return 1;
            end if;
            if Existing_Branch /= ""
              and then Existing_Branch /= To_String (Ctx.Branch)
            then
               Complain
                 (Env,
                  Prog & ": " & Dir & "/ records branch '" & Existing_Branch &
                  "', not '" & To_String (Ctx.Branch) & "'" & LF &
                  "  the directory name and its branch field disagree -- " &
                  "refusing to write" & LF);
               return 1;
            end if;
         end;
      end if;

      --  A sanitised title silently breaks inbound wikilinks.
      declare
         File_Title : constant String := Emit.File_Title (Title);
         Node_File  : constant String := File_Title & ".md";
         Existing   : Unbounded_String;
         Have_Node  : Boolean;
         Tail       : Unbounded_String;
      begin
         if File_Title /= Title then
            Complain
              (Env,
               Prog & ": WARNING title needed sanitizing, so [[" & Title &
               "]] will not resolve" & LF & "  filename: " & File_Title &
               ".md -- reword the title to avoid divergence" & LF);
         end if;

         --  Everything after the generated region is kept.
         Support.Read_File
           (Abs_Dir & "/" & Node_File, Largest_File, Existing, Have_Node);
         if Have_Node then
            declare
               Cut : constant Core.Node_Format.Split_Result :=
                 Core.Node_Format.Split (To_String (Existing));
            begin
               if Cut.Fenced then
                  declare
                     After : constant String  :=
                       To_String (Cut.Tail)
                         (To_String (Cut.Tail)'First +
                            Core.Node_Format.Generated_End'Length ..
                              To_String (Cut.Tail)'Last);
                     Start : constant Natural :=
                       (if After'Length /= 0 and then After (After'First) = LF
                        then After'First + 1
                        else After'First);
                     Kept  : String renames After (Start .. After'Last);
                     Last  : Natural          := Kept'Last;
                  begin
                     while Last >= Kept'First and then Kept (Last) = LF loop
                        Last := Last - 1;
                     end loop;
                     Tail := To_Unbounded_String (Kept (Kept'First .. Last));
                  end;

                  --  A second marker past the first means an earlier write
                  --  left the note malformed; carrying that forward would
                  --  fail later as an opaque schema violation.
                  declare
                     Kept : constant String := To_String (Tail);
                  begin
                     if Ada.Strings.Fixed.Index
                         (Kept, Core.Node_Format.Generated_Start) >
                       0
                       or else
                         Ada.Strings.Fixed.Index
                           (Kept, Core.Node_Format.Generated_End) >
                         0
                     then
                        Complain
                          (Env,
                           Prog & ": " & Node_File &
                           " already has a stray generated-region marker " &
                           "past its first `" &
                           Core.Node_Format.Generated_End &
                           "` -- refusing to write" & LF &
                           "  the note is structurally malformed (likely a " &
                           "duplicate marker left by an old write); repair " &
                           "it by hand before regenerating" & LF);
                        return 1;
                     end if;
                  end;
               end if;
            end;
         end if;

         --  The source list, deduplicated and byte sorted, every path checked
         --  before any is hashed, so a bad entry is named and not just an
         --  abort.
         declare
            Paths    : constant Lists.Vector :=
              Sorted_Unique (To_String (Item.Paths_Text));
            Contents : Text_Vector (1 .. Natural (Paths.Length));
            Bad      : Unbounded_String;
         begin
            for I in Contents'Range loop
               declare
                  Found : Boolean;
               begin
                  Support.Read_Repo_File
                    (Root, To_String (Paths (I)), Contents (I), Found);
                  if not Found then
                     Append (Bad, To_String (Paths (I)) & " ");
                  end if;
               end;
            end loop;
            if Length (Bad) /= 0 then
               Complain
                 (Env,
                  Prog & ": not regular files in " & Root & ": " &
                  Trimmed (To_String (Bad)) & LF &
                  "  (deleted since enumeration, or a submodule gitlink -- " &
                  "drop them from the list)" & LF);
               return 1;
            end if;

            declare
               Sources : Core.Graph_Model.Source_Vectors.Vector;
            begin
               for I in Contents'Range loop
                  Sources.Append
                    (Core.Graph_Model.Source_Ref'
                       (Path  => Paths (I),
                        Which =>
                          Core.Hashing.Blob_Hash (To_String (Contents (I)))));
               end loop;
               declare
                  Digest : constant String :=
                    Core.Node_Format.Sources_Digest (Sources);
                  Commit : constant String := Head_Commit (Env, Root);
               begin
                  if Commit /= "" then
                     Warn_Dirty_Sources (Env, Root, Paths, Commit);
                  end if;

                  if not Env.Vars.Get ("SYNAPSE_DISABLE_SYMBOL_CACHE").Found
                  then
                     Refresh_Tags_Cache (Env, Ctx, Paths, Contents);
                  end if;

                  return
                    Finish
                      (Env, Ctx, Item, Paths, Sources, Digest, Commit, Tail,
                       Node_File, Line);
               end;
            end;
         end;
      end;
   end Write;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Title, Summary, Paths_File, Body_File : Unbounded_String;
      I                                     : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg   : constant String := To_String (Args (I));
            Value : Unbounded_String;
            Found : Boolean;
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg in "--title" | "--summary" | "--paths" | "--body" then
               Cli_Args.Take_Value (Args, I, Value, Found);
               if not Found then
                  return Usage_Error (Env, Usage_Text);
               end if;
               if Arg = "--title" then
                  Title := Value;
               elsif Arg = "--summary" then
                  Summary := Value;
               elsif Arg = "--paths" then
                  Paths_File := Value;
               else
                  Body_File := Value;
               end if;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
         I := I + 1;
      end loop;
      if Length (Title) = 0 or else Length (Summary) = 0
        or else Length (Paths_File) = 0 or else Length (Body_File) = 0
      then
         return Usage_Error (Env, Usage_Text);
      end if;

      declare
         Paths_Text, Body_Text : Unbounded_String;
         Read                  : Boolean;
      begin
         Support.Read_File
           (To_String (Paths_File), Largest_File, Paths_Text, Read);
         if not Read or else Length (Paths_Text) = 0 then
            Complain
              (Env,
               Prog & ": empty path list: " & To_String (Paths_File) & LF);
            return 1;
         end if;
         Support.Read_File
           (To_String (Body_File), Largest_File, Body_Text, Read);
         if not Read then
            Complain
              (Env, Prog & ": no body file: " & To_String (Body_File) & LF);
            return 1;
         end if;
         declare
            Found : constant Context.Maybe_Context :=
              Context.Resolve (Env, Prog);
            Line  : Unbounded_String;
            Code  : Exit_Code;
         begin
            if not Found.Found then
               return 1;
            end if;
            Code :=
              Write
                (Env, Found.Value,
                 (Title => Title, Summary => Summary, Paths_Text => Paths_Text,
                  Body_Text => Body_Text),
                 Line);
            Say (Env, To_String (Line));
            return Code;
         end;
      end;
   end Run;

end Synapse.Commands.Write_Node;
