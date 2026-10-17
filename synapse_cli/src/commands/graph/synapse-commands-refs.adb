with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.File_Byte_Source;
with Synapse.Adapters.Index_Map;
with Synapse.Adapters.Tags_Cache;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Refs;

package body Synapse.Commands.Refs is

   use Ada.Strings.Unbounded;
   use type Adapters.Tags_Cache.Issue;

   package Cache_Adapter renames Synapse.Adapters.Tags_Cache;
   package Support renames Synapse.Commands.Graph_Support;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   ---------------------------------------------------------------------------
   --  build-refs
   ---------------------------------------------------------------------------

   Build_Prog : constant String := "synapse-build-refs";

   Build_Usage : constant String :=
     "usage: synapse build-refs [--cache <path>] [--out <path>]" & LF & LF &
     "  --cache  the tags cache to project. Default " &
     "$SYNAPSE_WORK_DIR/_tags_cache.bin." & LF &
     "  --out    where to write the index. Default " &
     "$SYNAPSE_WORK_DIR/_refs.tsv." & LF;

   Rows : Unbounded_String;

   procedure Collect (Row : String) is
   begin
      Append (Rows, Row);
   end Collect;

   function Build
     (Env                  : Environment; Cache_In, Out_In : String;
      Have_Cache, Have_Out : Boolean) return Exit_Code
   is
      Cache_Path : Unbounded_String := To_Unbounded_String (Cache_In);
      Out_Path   : Unbounded_String := To_Unbounded_String (Out_In);
   begin
      --  The work directory supplies whichever default is missing, so naming
      --  both makes this usable on a cache of a repository not checked out.
      if not (Have_Cache and then Have_Out) then
         declare
            Work : constant Support.Maybe_Path :=
              Support.Work_Dir (Env, Build_Prog);
         begin
            if not Work.Found then
               return 1;
            end if;
            if not Have_Cache then
               Cache_Path := Work.Value & "/_tags_cache.bin";
            end if;
            if not Have_Out then
               Out_Path := Work.Value & "/_refs.tsv";
            end if;
         end;
      end if;

      if not Ada.Directories.Exists (To_String (Cache_Path)) then
         Complain
           (Env,
            Build_Prog & ": no tags cache at " & To_String (Cache_Path) &
            " -- run 'synapse tags-cache' first" & LF);
         return 1;
      end if;
      declare
         Cache : Cache_Adapter.Cache;
      begin
         Cache_Adapter.Open (Cache, To_String (Cache_Path));
         if Cache_Adapter.Discarded (Cache) /= Cache_Adapter.None then
            Complain
              (Env,
               Build_Prog & ": unreadable cache: " & To_String (Cache_Path) &
               LF);
            return 1;
         end if;
         --  Projected unsorted into memory: the sort needs the whole set.
         Rows := Null_Unbounded_String;
         declare
            Ignored : constant Natural :=
              Cache_Adapter.Write_Refs (Cache, Collect'Access);
            pragma Unreferenced (Ignored);
            Unsupported : constant Natural                :=
              Cache_Adapter.Unsupported_Count (Cache);
            Sorted      : constant Core.Refs.Sorted_Index :=
              Core.Refs.Sort_Unique (To_String (Rows));
         begin
            Rows := Null_Unbounded_String;
            --  Rebuilt by a rename and never appended to: the reader
            --  bisects this file, so half of one is a wrong answer.
            Adapters.Index_Map.Write_File
              (To_String (Out_Path), To_String (Sorted.Text));
            Complain
              (Env,
               Build_Prog & ": " &
               Core.Decimal_Image.Image (Sorted.Tally.Tags) & " tags (" &
               Core.Decimal_Image.Image (Sorted.Tally.Defs) & " def, " &
               Core.Decimal_Image.Image (Sorted.Tally.Refs) & " ref) over " &
               Core.Decimal_Image.Image (Sorted.Tally.Files) & " files, " &
               Core.Decimal_Image.Image (Unsupported) & " unsupported -> " &
               To_String (Out_Path) & LF);
            return 0;
         end;
      end;
   end Build;

   function Run_Build (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Cache_Path, Out_Path : Unbounded_String;
      Have_Cache, Have_Out : Boolean  := False;
      I                    : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Build_Usage);
               return 0;
            elsif Arg in "--cache" | "--out" then
               if I = Natural (Args.Length) then
                  return Usage_Error (Env, Build_Usage);
               end if;
               I := I + 1;
               if Arg = "--cache" then
                  Cache_Path := Args (I);
                  Have_Cache := True;
               else
                  Out_Path := Args (I);
                  Have_Out := True;
               end if;
            else
               return Usage_Error (Env, Build_Usage);
            end if;
         end;
         I := I + 1;
      end loop;
      return
        Build
          (Env, To_String (Cache_Path), To_String (Out_Path), Have_Cache,
           Have_Out);
   end Run_Build;

   ---------------------------------------------------------------------------
   --  callers
   ---------------------------------------------------------------------------

   Callers_Prog : constant String := "synapse-callers";

   Callers_Usage : constant String :=
     "usage: synapse callers <name> [--all] [--namespace <repo>@<branch>]" &
     LF & LF & "  <name>       exact symbol name (not a prefix, not a regex)" &
     LF & "  (default)    calls only, as path:line<TAB>calling expression" &
     LF & "  --all        every def and ref, as " &
     "def|ref<TAB>kind<TAB>path:line<TAB>expression" & LF &
     "  --namespace  read another checkout's already-built index, not the " &
     "cwd's --" & LF &
     "               read-only, no checkout of it needs to exist on disk" & LF;

   function Callers_Usage_Error (Env : Environment) return Exit_Code is
   begin
      Complain (Env, Callers_Usage);
      Cli_Args.Print_Map_For (Env, "callers");
      return 2;
   end Callers_Usage_Error;

   function Callers
     (Env : Environment; Name : String; All_Rows : Boolean; Refs_In : String;
      Have_Refs : Boolean; Namespace : String; Have_Namespace : Boolean)
      return Exit_Code
   is
      Refs_Path : Unbounded_String := To_Unbounded_String (Refs_In);
   begin
      if not Have_Refs then
         declare
            Work : constant Support.Maybe_Path :=
              (if Have_Namespace then
                 Support.Work_Dir_For_Namespace (Env, Namespace, Callers_Prog)
               else Support.Work_Dir (Env, Callers_Prog));
         begin
            if not Work.Found then
               return 1;
            end if;
            Refs_Path := Work.Value & "/_refs.tsv";
         end;
      end if;

      --  Not 0: a missing index is "could not run", distinct from no rows of
      --  one that was built, which is "checked, not called".
      declare
         Index : Adapters.File_Byte_Source.Source;
      begin
         begin
            Adapters.File_Byte_Source.Open (Index, To_String (Refs_Path));
         exception
            when others =>
               Complain
                 (Env,
                  Callers_Prog & ": no reference index at " &
                  To_String (Refs_Path) & " -- run `synapse build-refs`" & LF);
               return 1;
         end;
         declare
            Found    : constant Core.Refs.Row_Vectors.Vector :=
              Core.Refs.Find (Index, Name);
            Out_Text : Unbounded_String;
         begin
            for Row of Found loop
               if All_Rows then
                  Append
                    (Out_Text,
                     Row.Dir & HT & Row.Kind & HT & Row.Site & HT & Row.Expr &
                     LF);
               elsif Core.Refs.Is_Call (Row) then
                  Append (Out_Text, Row.Site & HT & Row.Expr & LF);
               end if;
            end loop;
            Say (Env, To_String (Out_Text));
            return 0;   --  whenever the index was readable, however few rows
         end;
      end;
   end Callers;

   function Run_Callers
     (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Name, Refs_Path, Namespace          : Unbounded_String;
      All_Rows, Have_Refs, Have_Namespace : Boolean  := False;
      I                                   : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Callers_Usage);
               return 0;
            elsif Arg = "--all" then
               All_Rows := True;
            elsif Arg in "--refs" | "--namespace" then
               if I = Natural (Args.Length) then
                  return Callers_Usage_Error (Env);
               end if;
               I := I + 1;
               if Arg = "--refs" then
                  Refs_Path := Args (I);
                  Have_Refs := True;
               else
                  Namespace      := Args (I);
                  Have_Namespace := True;
               end if;
            elsif Arg'Length > 0 and then Arg (Arg'First) = '-' then
               return Callers_Usage_Error (Env);
            elsif Length (Name) = 0 then
               Name := Args (I);
            else
               return Callers_Usage_Error (Env);
            end if;
         end;
         I := I + 1;
      end loop;
      if Length (Name) = 0 then
         return Callers_Usage_Error (Env);
      end if;
      if Have_Refs and then Have_Namespace then
         Complain
           (Env,
            Callers_Prog & ": --refs already names the index directly -- " &
            "--namespace has nothing to do" & LF);
         return 2;
      end if;
      return
        Callers
          (Env, To_String (Name), All_Rows, To_String (Refs_Path), Have_Refs,
           To_String (Namespace), Have_Namespace);
   end Run_Callers;

end Synapse.Commands.Refs;
