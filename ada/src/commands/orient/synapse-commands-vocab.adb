with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.Disk_Repo_Reader;
with Synapse.Adapters.Tags_Cache;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Enumerate;
with Synapse.Commands.Graph_Support;
with Synapse.Commands.Node_Lists;
with Synapse.Commands.Tagging_Support;
with Synapse.Commands.Tags_Cache;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Enumerate;
with Synapse.Core.Hashing;
with Synapse.Core.Kind_Synonyms;
with Synapse.Core.Gate;
with Synapse.Core.Grammar_Registry;
with Synapse.Core.Namespace;
with Synapse.Core.Tag_Payload;
with Synapse.Core.Vocab;
with Synapse.Core.Words;
with Synapse.Ports.Variables;

package body Synapse.Commands.Vocab is

   use Ada.Strings.Unbounded;
   use type Tagging_Support.Load_Status;
   use type Tags_Cache.Backfill_Outcome;

   package Support renames Synapse.Commands.Graph_Support;
   package Tagging renames Synapse.Commands.Tagging_Support;
   package Cache_Adapter renames Synapse.Adapters.Tags_Cache;

   Prog : constant String    := "synapse-vocab";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse vocab [--repo <path>] [--depth N] [--chunk N] " &
     "[--out <dir>] [--lists <dir>]" & LF &
     "                     [--distinctive-top N] [--distinctive-k N]" & LF;

   package Group_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Lists.Vector, Ada.Strings.Hash, "=", Lists.Vectors."=");

   package Count_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Natural, Ada.Strings.Hash, "=");

   procedure Bump (Counts : in out Count_Maps.Map; Key : String) is
   begin
      if Counts.Contains (Key) then
         Counts.Replace (Key, Counts (Key) + 1);
      else
         Counts.Insert (Key, 1);
      end if;
   end Bump;

   --  The group of a key such as `group<TAB>word`: up to the first tab.
   function Group_Of_Key (Key : String) return String is
   begin
      for I in Key'Range loop
         if Key (I) = HT then
            return Key (Key'First .. I - 1);
         end if;
      end loop;
      return Key;
   end Group_Of_Key;

   type Tally is record
      Key   : Unbounded_String;
      Count : Natural;
   end record;

   package Tally_Vectors is new Ada.Containers.Vectors (Positive, Tally);

   function Tallies (Counts : Count_Maps.Map) return Tally_Vectors.Vector is
      Result : Tally_Vectors.Vector;
   begin
      for Position in Counts.Iterate loop
         Result.Append
           (Tally'
              (Key   => To_Unbounded_String (Count_Maps.Key (Position)),
               Count => Count_Maps.Element (Position)));
      end loop;
      return Result;
   end Tallies;

   --  Count descending, then the group ascending: `sort -k2,2nr -k1,1`.
   function Biggest_First (A, B : Tally) return Boolean is
     (if A.Count /= B.Count then A.Count > B.Count else A.Key < B.Key);

   package Count_Sorting is new Tally_Vectors.Generic_Sorting
     ("<" => Biggest_First);

   --  The group ascending, then the count descending, then the whole key: a
   --  total order, so two runs over the same input are byte identical.
   function By_Group (A, B : Tally) return Boolean is
      Group_A : constant String := Group_Of_Key (To_String (A.Key));
      Group_B : constant String := Group_Of_Key (To_String (B.Key));
   begin
      if Group_A /= Group_B then
         return Group_A < Group_B;
      elsif A.Count /= B.Count then
         return A.Count > B.Count;
      end if;
      return A.Key < B.Key;
   end By_Group;

   package Group_Sorting is new Tally_Vectors.Generic_Sorting
     ("<" => By_Group);

   --  `group<TAB>thing<TAB>count` lines, which `groupwords.tsv` and
   --  `groupexts.tsv` share. Returns what it wrote.
   function Group_Table (Path : String; Pairs : Count_Maps.Map) return String
   is
      Rows     : Tally_Vectors.Vector := Tallies (Pairs);
      Out_Text : Unbounded_String;
   begin
      Group_Sorting.Sort (Rows);
      for Row of Rows loop
         Append
           (Out_Text,
            Row.Key & HT & Core.Decimal_Image.Image (Row.Count) & LF);
      end loop;
      Support.Write_File (Path, To_String (Out_Text));
      return To_String (Out_Text);
   end Group_Table;

   procedure Write_Counts (Out_Dir : String; Counts : Count_Maps.Map) is
      Rows     : Tally_Vectors.Vector := Tallies (Counts);
      Out_Text : Unbounded_String;
   begin
      Count_Sorting.Sort (Rows);
      for Row of Rows loop
         Append
           (Out_Text,
            Row.Key & HT & Core.Decimal_Image.Image (Row.Count) & LF);
      end loop;
      Support.Write_File (Out_Dir & "/counts.tsv", To_String (Out_Text));
   end Write_Counts;

   --  `group<TAB>parseable<TAB>total` for every group `counts` knows,
   --  including those with nothing parseable: the row `gate --parseable` looks
   --  for.
   procedure Write_Parseable
     (Path : String; Counts, Parseable : Count_Maps.Map)
   is
      Rows     : Tally_Vectors.Vector := Tallies (Counts);
      Out_Text : Unbounded_String;

      function By_Name (A, B : Tally) return Boolean is (A.Key < B.Key);

      package Sorting is new Tally_Vectors.Generic_Sorting ("<" => By_Name);
   begin
      Sorting.Sort (Rows);
      for Row of Rows loop
         declare
            Key  : constant String  := To_String (Row.Key);
            Have : constant Natural :=
              (if Parseable.Contains (Key) then Parseable.Element (Key)
               else 0);
         begin
            Append
              (Out_Text,
               Row.Key & HT & Core.Decimal_Image.Image (Have) & HT &
               Core.Decimal_Image.Image (Row.Count) & LF);
         end;
      end loop;
      Support.Write_File (Path, To_String (Out_Text));
   end Write_Parseable;

   --  `group<TAB>namespace<TAB>agree<TAB>total`: for each group with a
   --  declared namespace, the one most of its files declared, how many
   --  agreed and how many were counted. Over every kept path and not just
   --  the code: a crate declares its namespace in a file no grammar reads.
   procedure Write_Namespaces
     (Root, Path : String; Kept : Lists.Vector; Groups : Group_Maps.Map;
      Rules      : Core.Namespace.Registry)
   is
      package By_Group_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (String, Count_Maps.Map, Ada.Strings.Hash, "=", Count_Maps."=");
      Reader   : Adapters.Disk_Repo_Reader.Reader :=
        Adapters.Disk_Repo_Reader.Create (Root);
      Cache    : Core.Namespace.Build_Cache;
      Found    : By_Group_Maps.Map;
      Out_Text : Unbounded_String;
   begin
      if Core.Namespace.Is_Empty (Rules) then
         Support.Write_File (Path, "");
         return;
      end if;
      for Item of Kept loop
         declare
            File : constant String                    := To_String (Item);
            Rule : constant Core.Namespace.Maybe_Rule :=
              Core.Namespace.Rule_For_Path (Rules, File);
         begin
            if Rule.Found and then Groups.Contains (File) then
               declare
                  Declared : constant Core.Namespace.Maybe_Text :=
                    Core.Namespace.Extract
                      (Reader, Kept, File, Rule.Value.Which, Rule.Value.File,
                       To_String (Rule.Value.Prefix), Rule.Value.Terminator,
                       Cache);
               begin
                  if Declared.Found then
                     for Group of Groups.Element (File) loop
                        declare
                           Key : constant String := To_String (Group);
                        begin
                           if not Found.Contains (Key) then
                              Found.Insert (Key, Count_Maps.Empty_Map);
                           end if;
                           declare
                              Counts : Count_Maps.Map := Found (Key);
                           begin
                              Bump (Counts, To_String (Declared.Value));
                              Found.Replace (Key, Counts);
                           end;
                        end;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;

      declare
         Names : Lists.Vector;
         package Sorting is new Lists.Vectors.Generic_Sorting
           ("<" => Ada.Strings.Unbounded."<");
      begin
         for Position in Found.Iterate loop
            Names.Append (To_Unbounded_String (By_Group_Maps.Key (Position)));
         end loop;
         Sorting.Sort (Names);
         for Name of Names loop
            declare
               Counts : constant Count_Maps.Map := Found (To_String (Name));
               Best   : Unbounded_String;
               Best_N : Natural                 := 0;
               Total  : Natural                 := 0;
            begin
               for Position in Counts.Iterate loop
                  declare
                     Value : constant String  := Count_Maps.Key (Position);
                     N     : constant Natural := Count_Maps.Element (Position);
                  begin
                     Total := Total + N;
                     if N > Best_N
                       or else (N = Best_N and then Value < To_String (Best))
                     then
                        Best   := To_Unbounded_String (Value);
                        Best_N := N;
                     end if;
                  end;
               end loop;
               Append
                 (Out_Text,
                  Name & HT & Best & HT & Core.Decimal_Image.Image (Best_N) &
                  HT & Core.Decimal_Image.Image (Total) & LF);
            end;
         end loop;
      end;
      Support.Write_File (Path, To_String (Out_Text));
   end Write_Namespaces;

   type Options is record
      Repo, Out_Dir, Lists_Dir     : Unbounded_String;
      Has_Repo, Has_Out, Has_Lists : Boolean  := False;
      Depth                        : Positive := 2;
      Chunk                        : Natural  := 0;
      Distinctive_Top              : Positive := 8;
      Distinctive_K                : Positive := 20;
   end record;

   function Build
     (Env    : Environment; Opts : Options; Root, Out_Dir : String;
      Usable : Lists.Vector; Rules : Core.Namespace.Registry) return Exit_Code
   is
      Tracked : Lists.Vector;
      Failure : Enumerate.Listing_Failure;
      Kept    : Lists.Vector;
      Groups  : Group_Maps.Map;
      Counts  : Count_Maps.Map;
      use type Enumerate.Listing_Failure;
   begin
      Enumerate.Tracked_Files (Env, Root, Tracked, Failure);
      if Failure = Enumerate.Git_Failed then
         Complain (Env, Prog & ": git ls-files failed in " & Root & LF);
         return 1;
      elsif Failure = Enumerate.Grep_Failed then
         Complain (Env, Prog & ": grep failed" & LF);
         return 1;
      end if;

      --  path to the groups it belongs to: with `--lists` each node listing
      --  it, else the one directory prefix. A path two nodes list counts
      --  under both.
      if Opts.Has_Lists then
         declare
            Nodes : constant Node_Lists.Node_Vectors.Vector :=
              Node_Lists.Read (To_String (Opts.Lists_Dir));
         begin
            if Nodes.Is_Empty then
               Complain
                 (Env,
                  Prog & ": no NN.txt/NN.title pairs in " &
                  To_String (Opts.Lists_Dir) & LF);
               return 1;
            end if;
            for Node of Nodes loop
               for Path of Node.Paths loop
                  declare
                     Key : constant String := To_String (Path);
                  begin
                     if not Groups.Contains (Key) then
                        Groups.Insert (Key, Lists.Vectors.Empty_Vector);
                     end if;
                     declare
                        Updated : Lists.Vector := Groups (Key);
                     begin
                        Updated.Append (Node.Title);
                        Groups.Replace (Key, Updated);
                     end;
                     Bump (Counts, To_String (Node.Title));
                  end;
               end loop;
            end loop;
         end;
         --  Narrowed to what some list claims: an unowned file's
         --  vocabulary has nowhere to go.
         for Item of Tracked loop
            if Groups.Contains (To_String (Item)) then
               Kept.Append (Item);
            end if;
         end loop;
      else
         Kept := Tracked;
         for Item of Kept loop
            declare
               Key   : constant String := To_String (Item);
               Group : constant String :=
                 Core.Vocab.Group_Of (Key, Opts.Depth);
            begin
               if not Groups.Contains (Key) then
                  Groups.Insert (Key, Lists.Vectors.Empty_Vector);
               end if;
               declare
                  Updated : Lists.Vector := Groups (Key);
               begin
                  Updated.Append (To_Unbounded_String (Group));
                  Groups.Replace (Key, Updated);
               end;
               Bump (Counts, Group);
            end;
         end loop;
      end if;

      Write_Counts (Out_Dir, Counts);

      --  Over every kept path and not just the code below: a group that is
      --  mostly data files says something a module name cannot, and needs
      --  no tagging.
      declare
         Mix : Count_Maps.Map;
      begin
         for Item of Kept loop
            declare
               Kind : constant String :=
                 Core.Vocab.Artifact_Of (To_String (Item));
            begin
               for Group of Groups (To_String (Item)) loop
                  Bump (Mix, To_String (Group) & HT & Kind);
               end loop;
            end;
         end loop;
         declare
            Ignored : constant String :=
              Group_Table (Out_Dir & "/groupexts.tsv", Mix);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      end;

      Write_Namespaces
        (Root, Out_Dir & "/namespaces.tsv", Kept, Groups, Rules);

      --  The code: a usable grammar, and not machine output that happens to
      --  end in a code extension. What is parseable is counted off the same
      --  membership.
      declare
         Code      : Lists.Vector;
         Parseable : Count_Maps.Map;
      begin
         for Item of Kept loop
            declare
               File : constant String := To_String (Item);
            begin
               if not Core.Enumerate.Is_Noise (File)
                 and then Support.Has_Usable_Extension (File, Usable)
               then
                  Code.Append (Item);
                  for Group of Groups.Element (File) loop
                     Bump (Parseable, To_String (Group));
                  end loop;
               end if;
            end;
         end loop;
         Write_Parseable (Out_Dir & "/parseable.tsv", Counts, Parseable);

         declare
            Words_Path : constant String := Out_Dir & "/groupwords.tsv";
         begin
            if Code.Is_Empty then
               Support.Write_File (Words_Path, "");
               Complain
                 (Env,
                  Prog & ": no files with a supported grammar -- use " &
                  "synapse-orientation instead" & LF);
               return 0;
            end if;

            declare
               Stopwords : constant Core.Text_Lists.Set :=
                 Adapters.Conf_Files.Load_Stopwords (Env.Vars.all);
               Cache     : Cache_Adapter.Cache;
               Requested : Cache_Adapter.Path_Hash_Vectors.Vector;
               Pairs     : Count_Maps.Map;
            begin
               Cache_Adapter.Open (Cache, Out_Dir & "/_tags_cache.bin");

               --  Pass one: tag only what the cache lacks at its current
               --  hash. A file that cannot be read now (deleted, a submodule)
               --  is left out entirely.
               for Item of Code loop
                  declare
                     Content : Unbounded_String;
                     Read    : Boolean;
                  begin
                     Support.Read_File
                       (Root & "/" & To_String (Item), 64 * 1_024 * 1_024,
                        Content, Read);
                     if Read then
                        Requested.Append
                          (Cache_Adapter.Path_Hash'
                             (Path => Item,
                              Hash =>
                                Core.Hashing.Blob_Hash (To_String (Content))));
                     end if;
                  end;
               end loop;
               case Tags_Cache.Backfill_Detailed
                 (Env, Root, Cache, Requested, Opts.Chunk)
               is
                  when Tags_Cache.Done =>
                     null;

                  when Tags_Cache.Could_Not_Tag =>
                     Complain (Env, Prog & ": a tagging worker failed" & LF);
                     return 1;

                     --  Not fatal: the counts and extension tables are on
                     --  disk, and pass two reads whatever the cache holds.
                  when Tags_Cache.Could_Not_Commit =>
                     Complain
                       (Env,
                        Prog & ": tags cache write failed (non-fatal)" & LF);
               end case;

               --  Pass two: every code file's vocabulary out of the cache.
               for Item of Code loop
                  declare
                     File : constant String := To_String (Item);
                     Got  : constant Cache_Adapter.Maybe_Value :=
                       Cache_Adapter.Get (Cache, File);
                  begin
                     if Got.Found and then not Got.Value.Unsupported then
                        for Tag of Core.Tag_Payload.Decode
                          (To_String (Got.Value.Tags))
                        loop
                           for Word of Core.Words.Split_Words
                             (To_String (Tag.Name))
                           loop
                              if Core.Words.Keep (To_String (Word), Stopwords)
                              then
                                 for Group of Groups.Element (File) loop
                                    Bump
                                      (Pairs,
                                       To_String (Group) & HT &
                                       To_String (Word));
                                 end loop;
                              end if;
                           end loop;
                        end loop;
                     end if;
                  end;
               end loop;

               declare
                  Text : constant String := Group_Table (Words_Path, Pairs);
                  Rows      : constant Core.Gate.Row_Vectors.Vector :=
                    Core.Gate.Judge_Distinctiveness
                      (Text,
                       (Top => Opts.Distinctive_Top, K => Opts.Distinctive_K));
                  Body_Text : Unbounded_String;
               begin
                  for Row of Rows loop
                     Append (Body_Text, Core.Gate.Distinctiveness_Line (Row));
                  end loop;
                  Support.Write_File
                    (Out_Dir & "/distinctive.tsv", To_String (Body_Text));
                  Complain
                    (Env,
                     Prog & ": groups " &
                     Core.Decimal_Image.Image (Natural (Counts.Length)) &
                     ", files " &
                     Core.Decimal_Image.Image (Natural (Kept.Length)) &
                     ", code " &
                     Core.Decimal_Image.Image (Natural (Code.Length)) &
                     ", pairs " &
                     Core.Decimal_Image.Image (Natural (Pairs.Length)) &
                     " -> " & Out_Dir & LF);
                  return 0;
               end;
            end;
         end;
      end;
   end Build;

   function Number_Argument (Raw : String; Value : out Natural) return Boolean
   is
   begin
      Value := 0;
      if Raw'Length = 0 or else not (for all C of Raw => C in '0' .. '9') then
         return False;
      end if;
      Value := Natural'Value (Raw);
      return True;
   exception
      when Constraint_Error =>
         return False;
   end Number_Argument;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Opts : Options;
      I    : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg   : constant String := To_String (Args (I));
            Value : Unbounded_String;
            Found : Boolean;
            N     : Natural;
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg in
                "--repo" | "--out" | "--lists" | "--depth" | "--chunk"
                | "--distinctive-top" | "--distinctive-k"
            then
               Cli_Args.Take_Value (Args, I, Value, Found);
               if not Found then
                  return Usage_Error (Env, Usage_Text);
               end if;
               if Arg = "--repo" then
                  Opts.Repo     := Value;
                  Opts.Has_Repo := True;
               elsif Arg = "--out" then
                  Opts.Out_Dir := Value;
                  Opts.Has_Out := True;
               elsif Arg = "--lists" then
                  Opts.Lists_Dir := Value;
                  Opts.Has_Lists := True;
               elsif not Number_Argument (To_String (Value), N) then
                  return Usage_Error (Env, Usage_Text);
               elsif Arg = "--chunk" then
                  Opts.Chunk := N;
               elsif Arg = "--depth" then
                  if N < 1 then
                     return Usage_Error (Env, Usage_Text);
                  end if;
                  Opts.Depth := N;
               elsif Arg = "--distinctive-top" then
                  if N < 1 then
                     return Usage_Error (Env, Usage_Text);
                  end if;
                  Opts.Distinctive_Top := N;
               elsif Arg = "--distinctive-k" then
                  if N < 1 then
                     return Usage_Error (Env, Usage_Text);
                  end if;
                  Opts.Distinctive_K := N;
               end if;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
         I := I + 1;
      end loop;

      --  Keyed on the repository being read, not where the command ran.
      declare
         Configured : constant Ports.Variables.Maybe_Value :=
           Env.Vars.Get ("SYNAPSE_WORK_DIR");
         Out_Dir    : Unbounded_String;
      begin
         if Opts.Has_Out then
            Out_Dir := Opts.Out_Dir;
         elsif Configured.Found then
            Out_Dir := Configured.Value;
         else
            declare
               Derived : constant Support.Maybe_Path :=
                 Support.Work_Dir
                   (Env, Prog,
                    (if Opts.Has_Repo then To_String (Opts.Repo) else "."));
            begin
               if not Derived.Found then
                  Complain
                    (Env, Prog & ": no --out and no SYNAPSE_WORK_DIR" & LF);
                  return 1;
               end if;
               Out_Dir := Derived.Value;
            end;
         end if;
         begin
            Ada.Directories.Create_Path (To_String (Out_Dir));
         exception
            when others =>
               Complain
                 (Env, Prog & ": cannot write " & To_String (Out_Dir) & LF);
               return 1;
         end;

         if Opts.Has_Lists
           and then not Ada.Directories.Exists (To_String (Opts.Lists_Dir))
         then
            Complain
              (Env,
               Prog & ": no such lists dir: " & To_String (Opts.Lists_Dir) &
               LF);
            return 1;
         end if;

         declare
            Root : constant String :=
              Support.Repo_Root
                (Env, (if Opts.Has_Repo then To_String (Opts.Repo) else ""));
         begin
            if Root = "" then
               Complain (Env, Prog & ": not inside a git repo" & LF);
               return 1;
            end if;
            if not Env.Vars.Get ("HOME").Found then
               return 1;
            end if;
            declare
               Registry      : Core.Grammar_Registry.Registry;
               Registry_Path : Unbounded_String;
               Rules         : Core.Kind_Synonyms.Rule_List;
               Rules_Path    : Unbounded_String;
               Namespaces    : Core.Namespace.Registry;
               Status        : Tagging.Load_Status;
               Rules_Ok      : Boolean;
            begin
               Tagging.Load_Registry (Env, Registry, Registry_Path, Status);
               if Status /= Tagging.Loaded then
                  Complain
                    (Env, Prog & ": cannot read the grammar registry" & LF);
                  return 1;
               end if;
               Tagging.Load_Rules (Env, Rules, Rules_Path, Status);
               if Status /= Tagging.Loaded then
                  Complain
                    (Env,
                     Prog & ": cannot read the kind-synonyms registry" & LF);
                  return 1;
               end if;
               Support.Load_Rule_Registry
                 (Env, "SYNAPSE_NAMESPACE_RULES_CONF",
                  "synapse-namespace-rules.conf", Namespaces, Rules_Ok);
               if not Rules_Ok then
                  Complain
                    (Env,
                     Prog & ": cannot read the namespace-rules registry" & LF);
                  return 1;
               end if;
               return
                 Build
                   (Env, Opts, Root, To_String (Out_Dir),
                    Core.Grammar_Registry.Usable_Extensions (Registry),
                    Namespaces);
            end;
         end;
      end;
   end Run;

end Synapse.Commands.Vocab;
