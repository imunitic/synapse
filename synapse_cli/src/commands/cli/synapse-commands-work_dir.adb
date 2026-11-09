with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;

with Synapse.Adapters.Work_Dirs;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;

package body Synapse.Commands.Work_Dir is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;

   Prog : constant String    := "synapse-work-dir";
   LF   : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse work-dir [--root | --list | --namespace <repo>@<branch>]"
     & LF;

   Help_Text : constant String :=
     Usage_Text & LF
     & "Prints where Synapse keeps its working files: the folder of this "
     & "repository's" & LF
     & "namespace, or with --namespace that of another, or with --root the "
     & "directory" & LF
     & "they are folders of. The root is SYNAPSE_WORK_DIR, else "
     & ".cache/synapse/work in" & LF
     & "the home directory. With --list, each namespace that has an index, a "
     & "reference" & LF
     & "index or a tags cache there: its name, a tab and which of index, refs "
     & "and tags it" & LF
     & "has. Nothing is created." & LF;

   --  The namespaces in Root that have something of a graph's local files,
   --  with which, as `name<TAB>index,refs,tags`, sorted by name.
   function Namespaces (Root : String) return String is
      Names  : Synapse.Core.Text_Lists.Sets.Set;
      Text   : Unbounded_String;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      use type Ada.Directories.File_Kind;
   begin
      if not Ada.Directories.Exists (Root)
        or else Ada.Directories.Kind (Root) /= Ada.Directories.Directory
      then
         return "";
      end if;
      Ada.Directories.Start_Search
        (Search, Root, "",
         [Ada.Directories.Directory => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name not in "." | ".."
              and then (for some C of Name => C = '@')
            then
               Names.Include (Name);
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      for Name of Names loop
         declare
            Folder : constant String := Root & "/" & Name;
            Has    : Unbounded_String;

            procedure Note (File, Label : String) is
            begin
               if Ada.Directories.Exists (Folder & "/" & File) then
                  Append (Has, (if Length (Has) = 0 then "" else ",") & Label);
               end if;
            end Note;
         begin
            Note ("_index.bin", "index");
            Note ("_refs.tsv", "refs");
            Note ("_tags_cache.bin", "tags");
            if Length (Has) > 0 then
               Append (Text, Name & ASCII.HT & To_String (Has) & LF);
            end if;
         end;
      end loop;
      return To_String (Text);
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         return To_String (Text);
   end Namespaces;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Count : constant Natural := Natural (Args.Length);
   begin
      if Count = 1 and then Cli_Args.Is_Help (To_String (Args (1))) then
         Say (Env, Help_Text);
         return 0;
      elsif Count = 1 and then To_String (Args (1)) = "--root" then
         declare
            Root : constant String :=
              Synapse.Adapters.Work_Dirs.Root (Env.Vars.all);
         begin
            if Root = "" then
               Complain
                 (Env, Prog & ": no HOME, so no default work dir" & LF);
               return 1;
            end if;
            Say (Env, Root & LF);
            return 0;
         end;
      elsif Count = 1 and then To_String (Args (1)) = "--list" then
         declare
            Root : constant String :=
              Synapse.Adapters.Work_Dirs.Root (Env.Vars.all);
         begin
            if Root = "" then
               Complain
                 (Env, Prog & ": no HOME, so no default work dir" & LF);
               return 1;
            end if;
            Say (Env, Namespaces (Root));
            return 0;
         end;
      elsif Count = 2 and then To_String (Args (1)) = "--namespace" then
         declare
            Where : constant Support.Maybe_Path :=
              Support.Work_Dir_For_Namespace
                (Env, To_String (Args (2)), Prog);
         begin
            if not Where.Found then
               return 1;
            end if;
            Say (Env, To_String (Where.Value) & LF);
            return 0;
         end;
      elsif Count = 0 then
         declare
            Where : constant Support.Maybe_Path :=
              Support.Work_Dir (Env, Prog);
         begin
            if not Where.Found then
               return 1;
            end if;
            Say (Env, To_String (Where.Value) & LF);
            return 0;
         end;
      end if;
      return Usage_Error (Env, Usage_Text);
   end Run;

end Synapse.Commands.Work_Dir;
