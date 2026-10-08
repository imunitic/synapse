with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Node_Query;

package body Synapse.Hooks.Prompt_Context is

   use Ada.Strings.Unbounded;

   --  Every `*.md` directly under the namespace but `Index.md`.
   function Count_Nodes (Dir : String) return Natural is
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      Count  : Natural := 0;
   begin
      if not Ada.Directories.Exists (Dir) then
         return 0;
      end if;
      Ada.Directories.Start_Search
        (Search, Dir, "*.md",
         [Ada.Directories.Ordinary_File => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         if Ada.Directories.Simple_Name (Item) /= "Index.md" then
            Count := Count + 1;
         end if;
      end loop;
      Ada.Directories.End_Search (Search);
      return Count;
   exception
      when others =>
         return 0;
   end Count_Nodes;

   function Build (Env : Environment; Cwd : String) return Common.Maybe_Text is
      Vault : constant Common.Maybe_Text := Common.Vault (Env);
   begin
      if not Vault.Found then
         return (Found => False);
      end if;
      declare
         Found : constant Common.Maybe_Namespace :=
           Common.Resolve_Namespace (Env, Cwd);
      begin
         if not Found.Found then
            return (Found => False);
         end if;
         declare
            Key    : constant String := To_String (Found.Value.Key);
            Ns_Dir : constant String                     :=
              To_String (Vault.Value) & "/synapse/" & Key;
            Index  : constant String                     :=
              Adapters.File_Bytes.Read
                (Ns_Dir & "/Index.md", 64 * 1_024 * 1_024);
            Remote : constant Core.Node_Query.Maybe_Text :=
              Core.Node_Query.Field (Index, "remote");
         begin
            --  The remote and not the branch, unlike the write paths: two
            --  repositories can share a key, and pointing at another
            --  project's graph is worse than silence.
            if not Remote.Found or else Length (Remote.Value) = 0
              or else Remote.Value /= Found.Value.Remote
            then
               return (Found => False);
            end if;
            declare
               Nodes      : constant Natural           := Count_Nodes (Ns_Dir);
               Work : constant Common.Maybe_Text := Common.Work_Dir (Env, Key);
               Have_Cache : constant Boolean           :=
                 Work.Found
                 and then Ada.Directories.Exists
                   (To_String (Work.Value) & "/_refs.tsv");
               Text       : Unbounded_String;
            begin
               if Nodes = 0 then
                  return (Found => False);
               end if;
               Append
                 (Text,
                  "Synapse: this repo has a code graph at " & Ns_Dir & "/ (" &
                  Core.Decimal_Image.Image (Nodes) &
                  " nodes). Query it FIRST for anything about this " &
                  "codebase -- `synapse query` for how something works, " &
                  "`synapse index lookup <path>` for which node owns a " &
                  "file. Do not grep or open source files until Synapse has " &
                  "named the file to read.");
               if Have_Cache then
                  Append
                    (Text,
                     " For an exact name, `synapse callers <name>` gives " &
                     "repo-wide call sites from the Code Cache -- use it, " &
                     "not grep.");
               end if;
               --  Scopes a query's answer and does not license a repo-wide
               --  re-check: line ranges come from the last build, so a
               --  mismatch is re-located in the named file, and the file wins
               --  over the graph.
               Append
                 (Text,
                  " Read only the files a query names; if its line range no " &
                  "longer matches, re-locate within that file, and trust " &
                  "the file over the graph. The synapse-query skill has the " &
                  "procedure.");
               return (Found => True, Value => Text);
            end;
         end;
      end;
   exception
      when others =>
         return (Found => False);
   end Build;

   procedure Run (Env : Environment) is
   begin
      if Env.Vars.Get ("SYNAPSE_DISABLE_PROMPT_INJECTION").Found then
         return;
      end if;
      declare
         Payload : constant Common.Payload    := Common.Read (Env);
         Prompt : constant Common.Maybe_Text := Common.Str (Payload, "prompt");
         Cwd     : constant Common.Maybe_Text := Common.Str (Payload, "cwd");
      begin
         --  An empty prompt is silence.
         if not Prompt.Found then
            return;
         end if;
         declare
            Text : constant Common.Maybe_Text :=
              Build (Env, (if Cwd.Found then To_String (Cwd.Value) else "."));
         begin
            if Text.Found then
               Common.Emit_Context
                 (Env, "UserPromptSubmit", To_String (Text.Value));
            end if;
         end;
      end;
   end Run;

end Synapse.Hooks.Prompt_Context;
