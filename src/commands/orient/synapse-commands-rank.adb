with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Long_Float_Text_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Tags_Cache;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;
with Synapse.Commands.Node_Lists;
with Synapse.Commands.Tagging_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Graph_Model;
with Synapse.Core.Grammar_Registry;
with Synapse.Core.Node_Format;
with Synapse.Core.Rank;
with Synapse.Core.Tag_Payload;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Variables;

package body Synapse.Commands.Rank is

   use Ada.Strings.Unbounded;
   use type Core.Graph_Model.Role;
   use type Tagging_Support.Load_Status;

   package Support renames Synapse.Commands.Graph_Support;
   package Tagging renames Synapse.Commands.Tagging_Support;
   package Cache_Adapter renames Synapse.Adapters.Tags_Cache;

   Prog : constant String    := "synapse-rank";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse rank --sources <file> [--repo <path>] [--out <dir>] " &
     "[--top N] [--tier code|dsl] [--pool summary|crux]" & LF &
     "       synapse rank --lists <dir>    [--repo <path>] [--out <dir>] " &
     "[--top N]" & LF;

   type Tier is (Code_Tier, Dsl_Tier);

   --  One ranked file. The score is a fraction for code and a whole count
   --  for the declarative tier.
   type Row is record
      Score : Long_Float;
      Path  : Unbounded_String;
   end record;

   package Row_Vectors is new Ada.Containers.Vectors (Positive, Row);

   function Better (A, B : Row) return Boolean is
     (if A.Score /= B.Score then A.Score > B.Score else A.Path < B.Path);

   package Row_Sorting is new Row_Vectors.Generic_Sorting ("<" => Better);

   package Text_Sorting is new Lists.Vectors.Generic_Sorting
     ("<" => Ada.Strings.Unbounded."<");

   function Image3 (Value : Long_Float) return String is
      Buffer : String (1 .. 40);
   begin
      Ada.Long_Float_Text_IO.Put (Buffer, Value, Aft => 3, Exp => 0);
      return Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both);
   end Image3;

   function Emit
     (Rows : Row_Vectors.Vector; Top : Natural; Which : Tier) return String
   is
      Limit    : constant Natural :=
        (if Top = 0 then Natural (Rows.Length)
         else Natural'Min (Top, Natural (Rows.Length)));
      Out_Text : Unbounded_String;
   begin
      for I in 1 .. Limit loop
         if Which = Code_Tier then
            Append
              (Out_Text,
               "code" & HT & Image3 (Rows (I).Score) & HT & Rows (I).Path &
               LF);
         else
            Append
              (Out_Text,
               "dsl" & HT &
               Core.Decimal_Image.Image (Long_Long_Integer (Rows (I).Score)) &
               HT & Rows (I).Path & LF);
         end if;
      end loop;
      return To_String (Out_Text);
   end Emit;

   function Has_Usable_Extension
     (Path : String; Usable : Lists.Vector) return Boolean renames
     Support.Has_Usable_Extension;

   --  Every distinct non blank line, trimmed, in byte order.
   function Deduplicated (Listing : String) return Lists.Vector is
      Result : Lists.Vector;
      Seen   : Core.Text_Lists.Set;
      Start  : Positive := Listing'First;
   begin
      for I in Listing'First .. Listing'Last + 1 loop
         if I > Listing'Last or else Listing (I) = LF then
            declare
               First : Positive := Start;
               Last  : Natural  := I - 1;
            begin
               while First <= Last
                 and then Listing (First) in ' ' | HT | ASCII.CR
               loop
                  First := First + 1;
               end loop;
               while Last >= First
                 and then Listing (Last) in ' ' | HT | ASCII.CR
               loop
                  Last := Last - 1;
               end loop;
               if Last >= First
                 and then not Seen.Contains (Listing (First .. Last))
               then
                  Seen.Include (Listing (First .. Last));
                  Result.Append
                    (To_Unbounded_String (Listing (First .. Last)));
               end if;
               Start := I + 1;
            end;
         end if;
      end loop;
      Text_Sorting.Sort (Result);
      return Result;
   end Deduplicated;

   procedure Split_Code
     (All_Paths     :     Lists.Vector; Usable : Lists.Vector;
      Code, Noncode : out Lists.Vector)
   is
   begin
      Code.Clear;
      Noncode.Clear;
      for Item of All_Paths loop
         if not Usable.Is_Empty
           and then Has_Usable_Extension (To_String (Item), Usable)
         then
            Code.Append (Item);
         else
            Noncode.Append (Item);
         end if;
      end loop;
   end Split_Code;

   --  The paths of Code without the tests: by the shipped rule, or by the
   --  person's own pattern, which `grep` reads.
   function Without_Tests
     (Env : Environment; Code : Lists.Vector) return Lists.Vector
   is
      Pattern : constant Ports.Variables.Maybe_Value :=
        Env.Vars.Get ("SYNAPSE_TEST_PATH_RE");
      Kept    : Lists.Vector;
   begin
      if Pattern.Found then
         declare
            Input   : Unbounded_String;
            Output  : Unbounded_String;
            Outcome : Support.Grep_Outcome;
            Start   : Positive := 1;
         begin
            for Item of Code loop
               Append (Input, Item & LF);
            end loop;
            Support.Grep
              (Env, "-vE", To_String (Pattern.Value), To_String (Input),
               Output, Outcome);
            declare
               Whole : constant String := To_String (Output);
            begin
               Start := Whole'First;
               for I in Whole'First .. Whole'Last + 1 loop
                  if I > Whole'Last or else Whole (I) = LF then
                     if I > Start then
                        Kept.Append
                          (To_Unbounded_String (Whole (Start .. I - 1)));
                     end if;
                     Start := I + 1;
                  end if;
               end loop;
            end;
         end;
         return Kept;
      end if;
      for Item of Code loop
         if not Core.Rank.Is_Test (To_String (Item)) then
            Kept.Append (Item);
         end if;
      end loop;
      return Kept;
   end Without_Tests;

   --  Definitions per kilobyte from the cache, which is never written. A
   --  path with no entry, or one no grammar could read, scores zero and stays
   --  in its tier. An empty or missing file is left out.
   function Rank_Code
     (Cache : in out Cache_Adapter.Cache; Root : String; Paths : Lists.Vector)
      return Row_Vectors.Vector
   is
      Rows : Row_Vectors.Vector;
   begin
      for Item of Paths loop
         declare
            Path : constant String   := To_String (Item);
            Full : constant String   := Root & "/" & Path;
            Size : Long_Long_Integer := 0;
         begin
            begin
               Size := Long_Long_Integer (Ada.Directories.Size (Full));
            exception
               when others =>
                  Size := -1;
            end;
            if Size > 0 then
               declare
                  Definitions : Natural                            := 0;
                  Entry_Value : constant Cache_Adapter.Maybe_Value :=
                    Cache_Adapter.Get (Cache, Path);
               begin
                  if Entry_Value.Found
                    and then not Entry_Value.Value.Unsupported
                  then
                     for Tag of Core.Tag_Payload.Decode
                       (To_String (Entry_Value.Value.Tags))
                     loop
                        if Tag.Which = Core.Graph_Model.Def then
                           Definitions := Definitions + 1;
                        end if;
                     end loop;
                  end if;
                  --  Rounded to three places before sorting: the output
                  --  never shows a difference below that, so ties are ordered
                  --  by what is printed.
                  Rows.Append
                    (Row'
                       (Score =>
                          Long_Float'Rounding
                            (Core.Rank.Density (Definitions, Positive (Size)) *
                             1_000.0) /
                          1_000.0,
                        Path  => Item));
               end;
            end if;
         end;
      end loop;
      Row_Sorting.Sort (Rows);
      return Rows;
   end Rank_Code;

   --  Every usable grammar path of the repository, bucketed by module: one
   --  listing shared by every node's declarative ranking.
   package Key_Vectors is new Ada.Containers.Vectors
     (Positive, Core.Rank.Key, Core.Rank."=");

   package Module_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Key_Vectors.Vector, Ada.Strings.Hash, "=", Key_Vectors."=");

   function Dsl_Index
     (Env : Environment; Root : String; Usable : Lists.Vector)
      return Module_Maps.Map
   is
      Result : Module_Maps.Map;
      Args   : Lists.Vector;
      Listed : Ports.Process_Runner.Result;
   begin
      Args.Append (To_Unbounded_String ("ls-files"));
      begin
         Listed :=
           Env.Runner.Run
             ("git", Args,
              (Cwd   => To_Unbounded_String (Root), Has_Stdin => False,
               Stdin => Null_Unbounded_String));
      exception
         when Ports.Process_Runner.Process_Failure =>
            return Result;
      end;
      if Listed.Exit_Code /= 0 then
         return Result;
      end if;
      declare
         Whole : constant String := To_String (Listed.Output);
         Start : Positive        := Whole'First;
      begin
         for I in Whole'First .. Whole'Last + 1 loop
            if I > Whole'Last or else Whole (I) = LF then
               declare
                  Last : Natural := I - 1;
               begin
                  if Last >= Start and then Whole (Last) = ASCII.CR then
                     Last := Last - 1;
                  end if;
                  if Last >= Start
                    and then Has_Usable_Extension
                      (Whole (Start .. Last), Usable)
                  then
                     declare
                        Item   : constant Core.Rank.Key :=
                          Core.Rank.Key_Of (Whole (Start .. Last));
                        Module : constant String := To_String (Item.Module);
                     begin
                        if not Result.Contains (Module) then
                           Result.Insert (Module, Key_Vectors.Empty_Vector);
                        end if;
                        declare
                           Bucket : Key_Vectors.Vector := Result (Module);
                        begin
                           Bucket.Append (Item);
                           Result.Replace (Module, Bucket);
                        end;
                     end;
                  end if;
               end;
               Start := I + 1;
            end if;
         end loop;
      end;
      return Result;
   end Dsl_Index;

   --  Which code file consumes each declaration, and how many, searched in
   --  the whole repository and not within the sources: a declaration's
   --  consumer is often outside its node.
   function Rank_Dsl
     (Index : Module_Maps.Map; Declarations : Lists.Vector)
      return Row_Vectors.Vector
   is
      package Served_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (String, Natural);
      Served : Served_Maps.Map;
      Rows   : Row_Vectors.Vector;
   begin
      for Declaration of Declarations loop
         declare
            Item   : constant Core.Rank.Key :=
              Core.Rank.Key_Of (To_String (Declaration));
            Module : constant String        := To_String (Item.Module);
         begin
            if Length (Item.Stem) >= Core.Rank.Min_Stem
              and then Index.Contains (Module)
            then
               for Candidate of Index (Module) loop
                  if Core.Rank.Consumes (Item, Candidate) then
                     declare
                        Path : constant String := To_String (Candidate.Path);
                     begin
                        if Served.Contains (Path) then
                           Served.Replace (Path, Served (Path) + 1);
                        else
                           Served.Insert (Path, 1);
                        end if;
                     end;
                  end if;
               end loop;
            end if;
         end;
      end loop;
      for Position in Served.Iterate loop
         Rows.Append
           (Row'
              (Score => Long_Float (Served_Maps.Element (Position)),
               Path  => To_Unbounded_String (Served_Maps.Key (Position))));
      end loop;
      Row_Sorting.Sort (Rows);
      return Rows;
   end Rank_Dsl;

   function Count (Rows : Row_Vectors.Vector) return String is
     (Core.Decimal_Image.Image (Natural (Rows.Length)));

   type Options is record
      Sources, Lists_Dir, Repo, Out_Dir, Tier_Name, Pool : Unbounded_String;
      Has_Sources, Has_Lists, Has_Repo, Has_Out, Has_Tier,
      Has_Pool                                           : Boolean := False;
      Top                                                : Natural := 10;
   end record;

   function Run_Lists
     (Env    : Environment; Cache : in out Cache_Adapter.Cache;
      Usable : Lists.Vector; Root, Lists_Dir, Work_Dir : String; Top : Natural)
      return Exit_Code
   is
      Index    : constant Module_Maps.Map := Dsl_Index (Env, Root, Usable);
      Rank_Dir : constant String          := Work_Dir & "/rank";
      Nodes    : Natural                  := 0;
   begin
      begin
         Ada.Directories.Create_Path (Rank_Dir);
      exception
         when others =>
            Complain (Env, Prog & ": cannot write " & Rank_Dir & LF);
            return 1;
      end;
      for N in 1 .. Core.Node_Format.Max_Nodes loop
         declare
            Slug    : constant String := Node_Lists.Slug (N);
            Listing : Unbounded_String;
            Have    : Boolean;
         begin
            Support.Read_File
              (Lists_Dir & "/" & Slug & ".txt", 64 * 1_024 * 1_024, Listing,
               Have);
            if Have then
               declare
                  Every         : constant Lists.Vector :=
                    Deduplicated (To_String (Listing));
                  Code, Noncode : Lists.Vector;
               begin
                  Split_Code (Every, Usable, Code, Noncode);
                  declare
                     Crux_Code    : constant Lists.Vector       :=
                       Without_Tests (Env, Code);
                     Dropped      : constant Natural            :=
                       Natural (Code.Length) - Natural (Crux_Code.Length);
                     Crux_Rows    : constant Row_Vectors.Vector :=
                       Rank_Code (Cache, Root, Crux_Code);
                     Summary_Code : constant Row_Vectors.Vector :=
                       Rank_Code (Cache, Root, Code);
                     Summary_Dsl  : constant Row_Vectors.Vector :=
                       (if not Usable.Is_Empty and then not Noncode.Is_Empty
                        then Rank_Dsl (Index, Noncode)
                        else Row_Vectors.Empty_Vector);
                  begin
                     Support.Write_File
                       (Rank_Dir & "/" & Slug & ".summary.tsv",
                        Emit (Summary_Code, Top, Code_Tier) &
                        Emit (Summary_Dsl, Top, Dsl_Tier));
                     Support.Write_File
                       (Rank_Dir & "/" & Slug & ".crux.tsv",
                        Emit (Crux_Rows, Top, Code_Tier));
                     Complain
                       (Env,
                        Prog & ": node " & Slug & ", " &
                        Core.Decimal_Image.Image (Natural (Every.Length)) &
                        " sources -> code " & Count (Summary_Code) &
                        ", dsl-consumers " & Count (Summary_Dsl) &
                        ", unranked " &
                        Core.Decimal_Image.Image (Natural (Noncode.Length)) &
                        ", tests-excluded " &
                        Core.Decimal_Image.Image (Dropped) & LF);
                     Nodes := Nodes + 1;
                  end;
               end;
            end if;
         end;
      end loop;
      if Nodes = 0 then
         Complain
           (Env, Prog & ": no node lists (NN.txt) found in " & Lists_Dir & LF);
         return 1;
      end if;
      Complain
        (Env,
         Prog & ": " & Core.Decimal_Image.Image (Nodes) & " nodes ranked -> " &
         Rank_Dir & LF);
      return 0;
   end Run_Lists;

   function Rank (Env : Environment; Opts : Options) return Exit_Code is
      Root : constant String :=
        Support.Repo_Root
          (Env, (if Opts.Has_Repo then To_String (Opts.Repo) else ""));
   begin
      if Root = "" then
         Complain (Env, Prog & ": not inside a git repo" & LF);
         return 1;
      end if;

      --  Where `vocab` left the cache.
      declare
         Work_Dir   : Unbounded_String;
         Configured : constant Ports.Variables.Maybe_Value :=
           Env.Vars.Get ("SYNAPSE_WORK_DIR");
      begin
         if Opts.Has_Out then
            Work_Dir := Opts.Out_Dir;
         elsif Configured.Found then
            Work_Dir := Configured.Value;
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
               Work_Dir := Derived.Value;
            end;
         end if;

         if not Env.Vars.Get ("HOME").Found then
            return 1;
         end if;
         declare
            Registry      : Core.Grammar_Registry.Registry;
            Registry_Path : Unbounded_String;
            Status        : Tagging.Load_Status;
         begin
            Tagging.Load_Registry (Env, Registry, Registry_Path, Status);
            if Status /= Tagging.Loaded then
               Complain
                 (Env, Prog & ": cannot read the grammar registry" & LF);
               return 1;
            end if;
            declare
               Usable     : constant Lists.Vector :=
                 Core.Grammar_Registry.Usable_Extensions (Registry);
               Cache_Path : constant String       :=
                 To_String (Work_Dir) & "/_tags_cache.bin";
               Cache      : Cache_Adapter.Cache;
            begin
               Cache_Adapter.Open (Cache, Cache_Path);
               if Cache_Adapter.Count (Cache) = 0 then
                  Complain
                    (Env,
                     Prog & ": tags cache is empty (" & Cache_Path &
                     ") -- every code-tier score will be zero; run synapse " &
                     "vocab first" & LF);
               end if;

               if Opts.Has_Lists then
                  if not Ada.Directories.Exists (To_String (Opts.Lists_Dir))
                  then
                     Complain
                       (Env,
                        Prog & ": no such lists dir: " &
                        To_String (Opts.Lists_Dir) & LF);
                     return 1;
                  end if;
                  return
                    Run_Lists
                      (Env, Cache, Usable, Root, To_String (Opts.Lists_Dir),
                       To_String (Work_Dir), Opts.Top);
               end if;

               declare
                  Listing : Unbounded_String;
                  Have    : Boolean;
                  Crux    : constant Boolean :=
                    Opts.Has_Pool and then To_String (Opts.Pool) = "crux";
               begin
                  Support.Read_File
                    (To_String (Opts.Sources), 64 * 1_024 * 1_024, Listing,
                     Have);
                  if not Have then
                     Complain
                       (Env,
                        Prog & ": no such sources file: " &
                        To_String (Opts.Sources) & LF);
                     return 1;
                  end if;
                  if Opts.Has_Pool
                    and then To_String (Opts.Pool) not in "summary" | "crux"
                  then
                     return Usage_Error (Env, Usage_Text);
                  end if;
                  declare
                     --  A crux is code: forced here and not checked at
                     --  every use.
                     Want          : constant String       :=
                       (if Crux then "code"
                        elsif Opts.Has_Tier then To_String (Opts.Tier_Name)
                        else "");
                     Every         : constant Lists.Vector :=
                       Deduplicated (To_String (Listing));
                     Code, Noncode : Lists.Vector;
                  begin
                     Split_Code (Every, Usable, Code, Noncode);
                     declare
                        Kept      : constant Lists.Vector       :=
                          (if Crux then Without_Tests (Env, Code) else Code);
                        Dropped   : constant Natural            :=
                          Natural (Code.Length) - Natural (Kept.Length);
                        Code_Rows : constant Row_Vectors.Vector :=
                          Rank_Code (Cache, Root, Kept);
                        Dsl_Only  : constant Boolean := Want = "dsl";
                        Code_Only : constant Boolean := Want = "code";
                        Dsl_Rows  : constant Row_Vectors.Vector :=
                          (if
                             not Code_Only and then not Usable.Is_Empty
                             and then not Noncode.Is_Empty
                           then
                             Rank_Dsl (Dsl_Index (Env, Root, Usable), Noncode)
                           else Row_Vectors.Empty_Vector);
                     begin
                        if not Dsl_Only then
                           Say (Env, Emit (Code_Rows, Opts.Top, Code_Tier));
                        end if;
                        if not Code_Only then
                           Say (Env, Emit (Dsl_Rows, Opts.Top, Dsl_Tier));
                        end if;
                        Complain
                          (Env,
                           Prog & ": pool " &
                           (if Opts.Has_Pool then To_String (Opts.Pool)
                            else "summary") &
                           ", " &
                           Core.Decimal_Image.Image (Natural (Every.Length)) &
                           " sources -> code " & Count (Code_Rows) &
                           ", dsl-consumers " & Count (Dsl_Rows) &
                           ", unranked " &
                           Core.Decimal_Image.Image
                             (Natural (Noncode.Length)) &
                           ", tests-excluded " &
                           Core.Decimal_Image.Image (Dropped) & LF);
                        return 0;
                     end;
                  end;
               end;
            end;
         end;
      end;
   end Rank;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Opts : Options;
      I    : Positive := 1;
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
            elsif Arg in
                "--sources" | "--lists" | "--repo" | "--out" | "--top"
                | "--tier" | "--pool"
            then
               Cli_Args.Take_Value (Args, I, Value, Found);
               if not Found then
                  return Usage_Error (Env, Usage_Text);
               end if;
               if Arg = "--sources" then
                  Opts.Sources     := Value;
                  Opts.Has_Sources := True;
               elsif Arg = "--lists" then
                  Opts.Lists_Dir := Value;
                  Opts.Has_Lists := True;
               elsif Arg = "--repo" then
                  Opts.Repo     := Value;
                  Opts.Has_Repo := True;
               elsif Arg = "--out" then
                  Opts.Out_Dir := Value;
                  Opts.Has_Out := True;
               elsif Arg = "--tier" then
                  Opts.Tier_Name := Value;
                  Opts.Has_Tier  := True;
               elsif Arg = "--pool" then
                  Opts.Pool     := Value;
                  Opts.Has_Pool := True;
               else
                  declare
                     Raw : constant String := To_String (Value);
                  begin
                     if Raw'Length = 0
                       or else not (for all C of Raw => C in '0' .. '9')
                     then
                        return Usage_Error (Env, Usage_Text);
                     end if;
                     Opts.Top := Natural'Value (Raw);
                  exception
                     when Constraint_Error =>
                        return Usage_Error (Env, Usage_Text);
                  end;
               end if;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
         I := I + 1;
      end loop;

      --  Exactly one input mode, and `--lists` ranks both pools, so a pool or
      --  a tier (which pick one for a single stream) mean nothing beside it.
      if Opts.Has_Sources = Opts.Has_Lists then
         return Usage_Error (Env, Usage_Text);
      end if;
      if Opts.Has_Lists and then (Opts.Has_Tier or else Opts.Has_Pool) then
         return Usage_Error (Env, Usage_Text);
      end if;
      if Opts.Has_Tier
        and then To_String (Opts.Tier_Name) not in "code" | "dsl"
      then
         return Usage_Error (Env, Usage_Text);
      end if;
      return Rank (Env, Opts);
   end Run;

end Synapse.Commands.Rank;
