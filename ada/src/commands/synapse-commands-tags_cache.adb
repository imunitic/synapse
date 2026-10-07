with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Unbounded;
with System.Multiprocessors;

with Synapse.Commands.Graph_Support;
with Synapse.Commands.Tagging_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Fault_Names;
with Synapse.Core.Graph_Model;
with Synapse.Core.Grammar_Registry;
with Synapse.Core.Kind_Synonyms;
with Synapse.Core.Tag_Line;
with Synapse.Core.Tag_Payload;
with Synapse.Ports.Extractor;
with Synapse.Ports.Extractor_Factory;

package body Synapse.Commands.Tags_Cache is

   use Ada.Strings.Unbounded;
   use type Adapters.Tags_Cache.Issue;
   use type Ports.Extractor.Outcome_Kind;

   package Cache_Adapter renames Synapse.Adapters.Tags_Cache;
   package Graph renames Synapse.Core.Graph_Model;
   package Support renames Synapse.Commands.Graph_Support;
   package Tagging renames Synapse.Commands.Tagging_Support;
   package Port renames Synapse.Ports.Extractor;

   use type Tagging.Load_Status;

   Prog : constant String    := "synapse-tags-cache";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse tags-cache --repo-root <dir> --cache <file> " &
     "--paths <tsv>" & LF & "       synapse tags-cache --dump <file>" & LF &
     "       synapse tags-cache --load <file>   (reads --dump's format on " &
     "stdin)" & LF & "       synapse tags-cache --refs <file>" & LF;

   function Issue_Name (Why : Cache_Adapter.Issue) return String is
     (Core.Fault_Names.Camel (Cache_Adapter.Issue'Image (Why)));

   --  What one task tags: its slice of the paths in, its outcomes out.
   type Slice is record
      Paths   : Lists.Vector;
      Results : Port.Outcome_Vectors.Vector;
      Failed  : Boolean := False;
   end record;

   type Slice_Access is access all Slice;

   type Extractor_Access is access all Port.Extractor'Class;
   type Text_Access is access constant String;

   task type Tag_Task is
      entry Start
        (Mine : Slice_Access; Using : Extractor_Access; Root : Text_Access);
   end Tag_Task;

   task body Tag_Task is
      Slot : Slice_Access;
      Ex   : Extractor_Access;
      From : Text_Access;
   begin
      accept Start
        (Mine : Slice_Access; Using : Extractor_Access; Root : Text_Access)
      do
         Slot := Mine;
         Ex   := Using;
         From := Root;
      end Start;
      begin
         Slot.Results := Ex.Extract (From.all, Slot.Paths);
      exception
         when others =>
            Slot.Failed := True;
      end;
   end Tag_Task;

   --  Every path's outcome, in the order of Paths. Raises when a task
   --  failed.
   function Tag_All
     (Env   : Environment; Repo_Root : String; Paths : Lists.Vector;
      Using : Ports.Extractor_Factory.Settings; Chunk : Natural)
      return Port.Outcome_Vectors.Vector
   is
      Cores   : constant Positive :=
        Positive (System.Multiprocessors.Number_Of_CPUs);
      Total   : constant Positive := Natural (Paths.Length);
      Size    : constant Positive :=
        (if Chunk > 0 then Chunk
         else Positive'Max (500, (Total + Cores - 1) / Cores));
      Workers : constant Positive :=
        Positive'Min (Cores, (Total + Size - 1) / Size);
   begin
      if Workers = 1 then
         return Env.Extractors.Locating (Using).Extract (Repo_Root, Paths);
      end if;
      declare
         Root   : aliased constant String := Repo_Root;
         Slots  : array (1 .. Workers) of aliased Slice;
         Result : Port.Outcome_Vectors.Vector;
         Failed : Boolean                 := False;
         Given  : Natural                 := 0;
      begin
         for W in Slots'Range loop
            declare
               Take : constant Natural :=
                 (if W = Workers then Total - Given
                  else Natural'Min (Size, Total - Given));
            begin
               for K in Given + 1 .. Given + Take loop
                  Slots (W).Paths.Append (Paths (K));
               end loop;
               Given := Given + Take;
            end;
         end loop;
         declare
            Tasks : array (1 .. Workers) of Tag_Task;
         begin
            for W in Tasks'Range loop
               Tasks (W).Start
                 (Slots (W)'Unchecked_Access,
                  Extractor_Access (Env.Extractors.Worker (Using, W)),
                  Root'Unchecked_Access);
            end loop;
         end;
         for Item of Slots loop
            Failed := Failed or else Item.Failed;
         end loop;
         if Failed then
            raise Program_Error with "a tagging worker failed";
         end if;
         for Item of Slots loop
            Result.Append (Item.Results);
         end loop;
         return Result;
      end;
   end Tag_All;

   function Backfill_Detailed
     (Env       :        Environment; Repo_Root : String;
      Cache     : in out Cache_Adapter.Cache;
      Requested : Cache_Adapter.Path_Hash_Vectors.Vector; Chunk : Natural := 0)
      return Backfill_Outcome
   is
      Need    : constant Cache_Adapter.Path_Hash_Vectors.Vector :=
        Cache_Adapter.Needs_Tagging (Cache, Requested);
      Updates : Cache_Adapter.Update_Vectors.Vector;
      Paths   : Lists.Vector;
      Ignored : Natural;
   begin
      if Need.Is_Empty then
         --  The common case. An absent cache must still exist afterwards.
         if not Cache_Adapter.Is_Open (Cache) then
            begin
               Ignored :=
                 Cache_Adapter.Commit
                   (Cache, Updates, Lists.Vectors.Empty_Vector);
            exception
               when others =>
                  return Could_Not_Commit;
            end;
         end if;
         return Done;
      end if;
      for Item of Need loop
         Paths.Append (Item.Path);
      end loop;

      declare
         Registry      : Core.Grammar_Registry.Registry;
         Registry_Path : Unbounded_String;
         Rules         : Core.Kind_Synonyms.Rule_List;
         Rules_Path    : Unbounded_String;
         Dir           : Unbounded_String;
         Have_Dir      : Boolean;
         Status        : Tagging.Load_Status;
      begin
         Tagging.Load_Registry (Env, Registry, Registry_Path, Status);
         if Status /= Tagging.Loaded then
            return Could_Not_Tag;
         end if;
         Tagging.Grammars_Dir (Env, Dir, Have_Dir);
         if not Have_Dir then
            return Could_Not_Tag;
         end if;
         Tagging.Load_Rules (Env, Rules, Rules_Path, Status);
         if Status /= Tagging.Loaded then
            return Could_Not_Tag;
         end if;
         declare
            Results : constant Port.Outcome_Vectors.Vector :=
              Tag_All
                (Env, Repo_Root, Paths,
                 Tagging.Settings_For (Env, Registry, To_String (Dir), Rules),
                 Chunk);
         begin
            for I in 1 .. Natural (Need.Length) loop
               if Results (I).Kind = Port.Unsupported then
                  Updates.Append
                    (Cache_Adapter.Update'
                       (Path  => Need (I).Path,
                        Which =>
                          (Hash        => Need (I).Hash,
                           Tags        => Null_Unbounded_String,
                           Unsupported => True)));
               else
                  Updates.Append
                    (Cache_Adapter.Update'
                       (Path  => Need (I).Path,
                        Which =>
                          (Hash        => Need (I).Hash,
                           Tags        =>
                             To_Unbounded_String
                               (Core.Tag_Payload.Encode (Results (I).Tags)),
                           Unsupported => False)));
               end if;
            end loop;
         end;
      exception
         when others =>
            return Could_Not_Tag;
      end;
      begin
         Ignored :=
           Cache_Adapter.Commit (Cache, Updates, Lists.Vectors.Empty_Vector);
      exception
         when others =>
            return Could_Not_Commit;
      end;
      return Done;
   end Backfill_Detailed;

   function Backfill
     (Env       :        Environment; Repo_Root : String;
      Cache     : in out Cache_Adapter.Cache;
      Requested :    Cache_Adapter.Path_Hash_Vectors.Vector) return Boolean is
     (Backfill_Detailed (Env, Repo_Root, Cache, Requested) = Done);

   function Update
     (Env : Environment; Repo_Root, Cache_Path, Paths_File : String)
      return Exit_Code
   is
      Listing   : Unbounded_String;
      Read      : Boolean;
      Requested : Cache_Adapter.Path_Hash_Vectors.Vector;
   begin
      if not Ada.Directories.Exists (Repo_Root) then
         Complain (Env, Prog & ": no such repo root: " & Repo_Root & LF);
         return 1;
      end if;
      Support.Read_File
        (Paths_File, Support.Max_Listing_Bytes (Env, 64 * 1_024 * 1_024),
         Listing, Read);
      if not Read then
         Complain (Env, Prog & ": unreadable paths file: " & Paths_File & LF);
         return 1;
      end if;
      declare
         Whole : constant String := To_String (Listing);
         Start : Positive        := Whole'First;
      begin
         for I in Whole'First .. Whole'Last + 1 loop
            if I > Whole'Last or else Whole (I) = LF then
               declare
                  Last : Natural := I - 1;
                  Tab  : Natural := 0;
               begin
                  if Last >= Start and then Whole (Last) = ASCII.CR then
                     Last := Last - 1;
                  end if;
                  --  The last tab: a path may contain one.
                  for K in reverse Start .. Last loop
                     if Whole (K) = HT then
                        Tab := K;
                        exit;
                     end if;
                  end loop;
                  if Tab > Start then
                     declare
                        Hash : constant Graph.Hash_Result :=
                          Graph.Hash_From_Hex (Whole (Tab + 1 .. Last));
                     begin
                        if Hash.Found then
                           Requested.Append
                             (Cache_Adapter.Path_Hash'
                                (Path =>
                                   To_Unbounded_String
                                     (Whole (Start .. Tab - 1)),
                                 Hash => Hash.Value));
                        end if;
                     end;
                  end if;
                  Start := I + 1;
               end;
            end if;
         end loop;
      end;

      declare
         Cache : Cache_Adapter.Cache;
      begin
         Cache_Adapter.Open (Cache, Cache_Path);
         if not Backfill (Env, Repo_Root, Cache, Requested) then
            Complain
              (Env, Prog & ": could not bring the cache up to date" & LF);
            return 1;
         end if;
         return 0;
      end;
   end Update;

   function Dump (Env : Environment; Path : String) return Exit_Code is
      Cache    : Cache_Adapter.Cache;
      Out_Text : Unbounded_String;
   begin
      Cache_Adapter.Open (Cache, Path);
      if Cache_Adapter.Discarded (Cache) /= Cache_Adapter.None then
         Complain
           (Env,
            Prog & ": unreadable cache (" &
            Issue_Name (Cache_Adapter.Discarded (Cache)) & "): " & Path & LF);
         return 1;
      end if;
      for I in 1 .. Cache_Adapter.Count (Cache) loop
         declare
            Name : Unbounded_String;
            Item : Cache_Adapter.Value;
         begin
            Cache_Adapter.Entry_At (Cache, I, Name, Item);
            Append
              (Out_Text,
               "H" & HT & Name & HT & Graph.Hash_To_Hex (Item.Hash) & LF);
            if Item.Unsupported then
               Append (Out_Text, "U" & HT & Name & LF);
            else
               Append (Out_Text, "P" & HT & Name & LF);
               for Tag of Core.Tag_Payload.Decode (To_String (Item.Tags)) loop
                  Append
                    (Out_Text,
                     "T" & HT & Name & HT & Tag.Name & HT & " | " & Tag.Kind &
                     HT & Graph.Image (Tag.Which) & " (" &
                     Core.Decimal_Image.Image (Tag.Line) & ", 0) - (" &
                     Core.Decimal_Image.Image (Tag.Line) & ", 0) `" &
                     Tag.Expression & "`" & LF);
               end loop;
            end if;
         end;
      end loop;
      Say (Env, To_String (Out_Text));
      return 0;
   end Dump;

   --  Builds a cache from `--dump`'s own text on standard input, so a test
   --  can make one with awkward tag lines.
   function Load (Env : Environment; Path : String) return Exit_Code is
      package Tag_Lists renames Core.Tag_Payload.Tag_Vectors;
      type Staged is record
         Path        : Unbounded_String;
         Hash        : Graph.Hash;
         Unsupported : Boolean := False;
         Tags        : Tag_Lists.Vector;
         Has_Tags    : Boolean := False;
      end record;
      package Staged_Vectors is new Ada.Containers.Vectors (Positive, Staged);

      Text  : constant String := Env.Console.Read_Stdin;
      Order : Staged_Vectors.Vector;
      Start : Positive        := Text'First;

      function Index_Of (Name : String) return Natural is
      begin
         for I in 1 .. Natural (Order.Length) loop
            if To_String (Order (I).Path) = Name then
               return I;
            end if;
         end loop;
         return 0;
      end Index_Of;
   begin
      for I in Text'First .. Text'Last + 1 loop
         if I > Text'Last or else Text (I) = LF then
            declare
               Last : Natural := I - 1;
            begin
               if Last >= Start and then Text (Last) = ASCII.CR then
                  Last := Last - 1;
               end if;
               if Last - Start + 1 >= 2 and then Text (Start + 1) = HT then
                  declare
                     Marker : constant Character := Text (Start);
                     Rest   : constant String    := Text (Start + 2 .. Last);
                     Tab    : Natural            := 0;
                  begin
                     for K in Rest'Range loop
                        if Rest (K) = HT then
                           Tab := K;
                           exit;
                        end if;
                     end loop;
                     case Marker is
                        when 'H' =>
                           if Tab > 0 then
                              declare
                                 Hash     : constant Graph.Hash_Result :=
                                   Graph.Hash_From_Hex
                                     (Rest (Tab + 1 .. Rest'Last));
                                 At_Index : constant Natural           :=
                                   Index_Of (Rest (Rest'First .. Tab - 1));
                              begin
                                 if Hash.Found then
                                    if At_Index = 0 then
                                       Order.Append
                                         (Staged'
                                            (Path   =>
                                               To_Unbounded_String
                                                 (Rest
                                                    (Rest'First .. Tab - 1)),
                                             Hash   => Hash.Value,
                                             others => <>));
                                    else
                                       Order (At_Index).Hash := Hash.Value;
                                    end if;
                                 end if;
                              end;
                           end if;

                        when 'U' =>
                           declare
                              At_Index : constant Natural := Index_Of (Rest);
                           begin
                              if At_Index > 0 then
                                 Order (At_Index).Unsupported := True;
                              end if;
                           end;

                        when 'T' =>
                           if Tab > 0 then
                              declare
                                 At_Index : constant Natural                 :=
                                   Index_Of (Rest (Rest'First .. Tab - 1));
                                 Parsed   : constant Core.Tag_Line.Maybe_Tag :=
                                   Core.Tag_Line.Parse
                                     (Rest (Tab + 1 .. Rest'Last));
                              begin
                                 if At_Index > 0 and then Parsed.Found then
                                    Order (At_Index).Tags.Append
                                      (Parsed.Value);
                                    Order (At_Index).Has_Tags := True;
                                 end if;
                              end;
                           end if;

                        when others =>
                           null;
                     end case;
                  end;
               end if;
               Start := I + 1;
            end;
         end if;
      end loop;

      declare
         Updates : Cache_Adapter.Update_Vectors.Vector;
         Cache   : Cache_Adapter.Cache;
         Written : Natural;
      begin
         for Item of Order loop
            Updates.Append
              (Cache_Adapter.Update'
                 (Path  => Item.Path,
                  Which =>
                    (Hash        => Item.Hash,
                     Tags        =>
                       (if Item.Has_Tags then
                          To_Unbounded_String
                            (Core.Tag_Payload.Encode (Item.Tags))
                        else Null_Unbounded_String),
                     Unsupported => Item.Unsupported)));
         end loop;
         Cache_Adapter.Open (Cache, Path);
         Written :=
           Cache_Adapter.Commit (Cache, Updates, Lists.Vectors.Empty_Vector);
         pragma Unreferenced (Written);
         return 0;
      exception
         when others =>
            Complain (Env, Prog & ": could not write the cache: " & Path & LF);
            return 1;
      end;
   end Load;

   Refs_Rows : Unbounded_String;

   procedure Collect (Row : String) is
   begin
      Append (Refs_Rows, Row);
   end Collect;

   --  `_refs.tsv` rows, unsorted: the reader binary-searches that file in the
   --  byte order of a sort, which is the caller's to apply.
   function Refs_From (Env : Environment; Path : String) return Exit_Code is
      Cache : Cache_Adapter.Cache;
      Rows  : Natural;
   begin
      Cache_Adapter.Open (Cache, Path);
      if Cache_Adapter.Discarded (Cache) /= Cache_Adapter.None then
         Complain
           (Env,
            Prog & ": unreadable cache (" &
            Issue_Name (Cache_Adapter.Discarded (Cache)) & "): " & Path & LF);
         return 1;
      end if;
      Refs_Rows := Null_Unbounded_String;
      Rows      := Cache_Adapter.Write_Refs (Cache, Collect'Access);
      pragma Unreferenced (Rows);
      Say (Env, To_String (Refs_Rows));
      Refs_Rows := Null_Unbounded_String;
      return 0;
   end Refs_From;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Repo_Root, Cache_Path, Paths_File, Dump_Path, Load_Path,
      Refs_Path : Unbounded_String;
      Have_Root, Have_Cache, Have_Paths, Have_Dump, Have_Load,
      Have_Refs : Boolean  := False;
      I         : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            --  Help must not need an environment.
            if Arg in "-h" | "--help" then
               Complain (Env, Usage_Text);
               return 0;
            end if;
            if Arg in
                "--repo-root" | "--cache" | "--paths" | "--dump" | "--load"
                | "--refs"
            then
               if I = Natural (Args.Length) then
                  return Usage_Error (Env, Usage_Text);
               end if;
               I := I + 1;
               if Arg = "--repo-root" then
                  Repo_Root := Args (I);
                  Have_Root := True;
               elsif Arg = "--cache" then
                  Cache_Path := Args (I);
                  Have_Cache := True;
               elsif Arg = "--paths" then
                  Paths_File := Args (I);
                  Have_Paths := True;
               elsif Arg = "--dump" then
                  Dump_Path := Args (I);
                  Have_Dump := True;
               elsif Arg = "--load" then
                  Load_Path := Args (I);
                  Have_Load := True;
               else
                  Refs_Path := Args (I);
                  Have_Refs := True;
               end if;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
         I := I + 1;
      end loop;

      if Have_Dump then
         return Dump (Env, To_String (Dump_Path));
      elsif Have_Load then
         return Load (Env, To_String (Load_Path));
      elsif Have_Refs then
         return Refs_From (Env, To_String (Refs_Path));
      elsif not (Have_Root and then Have_Cache and then Have_Paths) then
         return Usage_Error (Env, Usage_Text);
      end if;
      return
        Update
          (Env, To_String (Repo_Root), To_String (Cache_Path),
           To_String (Paths_File));
   end Run;

end Synapse.Commands.Tags_Cache;
