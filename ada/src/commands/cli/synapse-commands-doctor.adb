with Ada.Calendar;
with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.Git_Identity;
with Synapse.Adapters.Index_Map;
with Synapse.Adapters.Tree_Sitter.Preparation;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Doctor;
with Synapse.Core.Fault_Names;
with Synapse.Core.Identity;
with Synapse.Core.Node_Query;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Variables;

package body Synapse.Commands.Doctor is

   use Ada.Strings.Unbounded;

   package Report renames Synapse.Core.Doctor;
   package Support renames Synapse.Commands.Graph_Support;
   package Runner renames Synapse.Ports.Process_Runner;
   package Image renames Synapse.Core.Decimal_Image;

   use type Report.Status;
   use type Adapters.Index_Map.Issue;
   use type Ada.Calendar.Time;
   use type Ada.Directories.File_Kind;

   Prog : constant String    := "synapse-doctor";
   LF   : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse doctor [--repo <dir>]" & LF & LF &
     "  --repo  the checkout to examine. Default: the one containing $PWD." &
     LF;

   Largest_File : constant := 64 * 1_024 * 1_024;

   type Checks is record
      Items : Report.Check_Vectors.Vector;
   end record;

   procedure Add
     (Into   : in out Checks; Name : String; State : Report.Status;
      Detail :        String)
   is
   begin
      Into.Items.Append
        (Report.Check'
           (Name   => To_Unbounded_String (Name), State => State,
            Detail => To_Unbounded_String (Detail)));
   end Add;

   function Exists (Path : String) return Boolean is
     (Ada.Directories.Exists (Path));

   function Trimmed (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Text (First) in ' ' | ASCII.HT | ASCII.CR
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) in ' ' | ASCII.HT | ASCII.CR
      loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   --  A file's text, none after saying so when it is there and unreadable.
   procedure Read
     (Env   :     Environment; Path : String; Text : out Unbounded_String;
      Found : out Boolean)
   is
   begin
      Support.Read_File (Path, Largest_File, Text, Found);
      if not Found and then Exists (Path) then
         Complain (Env, Prog & ": could not read " & Path & LF);
      end if;
   end Read;

   ---------------------------------------------------------------------------
   --  git: every subcommand that starts it treats a failure as nothing found
   --  and not as the tool being missing.
   ---------------------------------------------------------------------------

   procedure Dependencies (Env : Environment; Into : in out Checks) is
      Args : Lists.Vector;
   begin
      Args.Append (To_Unbounded_String ("--version"));
      declare
         Done  : constant Runner.Result :=
           Env.Runner.Run ("git", Args, Runner.Options'(others => <>));
         Text  : constant String        := To_String (Done.Output);
         Break : constant Natural       :=
           Ada.Strings.Unbounded.Index (Done.Output, "" & LF);
      begin
         if not Runner.Succeeded (Done) then
            Add (Into, "git", Report.Fail, "not on PATH");
         else
            Add
              (Into, "git", Report.Ok,
               Trimmed
                 (if Break = 0 then Text else Text (Text'First .. Break - 1)));
         end if;
      end;
   exception
      when others =>
         Add (Into, "git", Report.Fail, "not on PATH");
   end Dependencies;

   ---------------------------------------------------------------------------
   --  The configuration and the vault directory.
   ---------------------------------------------------------------------------

   procedure Vault_Checks
     (Env   : Environment; Into : in out Checks; Vault : out Unbounded_String;
      Found : out Boolean)
   is
      Config : Support.Maybe_Path :=
        Adapters.Conf_Files.Resolve_Conf_Path
          (Env.Vars.all, Adapters.Conf_Files.Primary_Name);
   begin
      Found := False;
      if not Config.Found then
         Config :=
           Adapters.Conf_Files.Resolve_Conf_Path
             (Env.Vars.all, Adapters.Conf_Files.Legacy_Name);
      end if;
      if Config.Found then
         Add (Into, "config", Report.Ok, To_String (Config.Value));
      elsif Env.Vars.Get ("SYNAPSE_VAULT_DIR").Found then
         Add
           (Into, "config", Report.Warn,
            "no synapse.conf; using $SYNAPSE_VAULT_DIR");
      else
         Add
           (Into, "config", Report.Fail,
            "no synapse.conf found -- create one at " &
            "$XDG_CONFIG_HOME/synapse/synapse.conf (or " &
            "~/.config/synapse/synapse.conf), or ~/.claude/synapse.conf");
      end if;

      declare
         Dir : constant Support.Maybe_Path :=
           Adapters.Conf_Files.Vault_Dir (Env.Vars.all);
      begin
         if not Dir.Found then
            Add
              (Into, "vault", Report.Fail,
               "SYNAPSE_VAULT_DIR is not set anywhere");
            return;
         end if;
         declare
            Path : constant String := To_String (Dir.Value);
         begin
            if not Exists (Path) then
               Add (Into, "vault", Report.Fail, Path & " does not exist");
            elsif Ada.Directories.Kind (Path) /= Ada.Directories.Directory then
               Add (Into, "vault", Report.Fail, Path & " is not a directory");
            else
               Add (Into, "vault", Report.Ok, Path);
               Vault := Dir.Value;
               Found := True;
            end if;
         end;
      end;
   end Vault_Checks;

   ---------------------------------------------------------------------------
   --  The namespace this checkout resolves to.
   ---------------------------------------------------------------------------

   procedure Identity_Checks
     (Into     : in out Checks; Repo : String;
      Resolved :    out Core.Identity.Resolved; Found : out Boolean)
   is
   begin
      Found := False;
      begin
         Resolved := Adapters.Git_Identity.Resolve (Repo);
      exception
         when Core.Identity.Not_A_Git_Repo =>
            Add
              (Into, "repository", Report.Warn,
               "not inside a git repo -- nothing to graph here");
            return;

         when Core.Identity.Detached_Head =>
            Add
              (Into, "repository", Report.Warn,
               "detached HEAD -- a namespace is keyed by branch, so there " &
               "is none");
            return;

         when others =>
            Add (Into, "repository", Report.Fail, "could not resolve");
            return;
      end;
      Found := True;
      Add
        (Into, "repository", Report.Ok, To_String (Resolved.Where.Repo_Root));
      --  A worktree is where the two-hop lookup can go wrong, and seeing the
      --  git directory is how someone would notice it had.
      if Resolved.Where.Git_Dir /= Resolved.Where.Common_Dir then
         Add
           (Into, "worktree", Report.Ok,
            To_String (Resolved.Where.Git_Dir) & " (shared: " &
            To_String (Resolved.Where.Common_Dir) & ")");
      end if;
      Add (Into, "remote", Report.Ok, To_String (Resolved.Remote));
      Add (Into, "namespace", Report.Ok, To_String (Resolved.Key));
   end Identity_Checks;

   ---------------------------------------------------------------------------
   --  Whether the namespace exists and agrees about which repository and
   --  branch it describes.
   ---------------------------------------------------------------------------

   procedure Namespace_Checks
     (Env      : Environment; Into : in out Checks; Vault : String;
      Resolved : Core.Identity.Resolved)
   is
      Key  : constant String := To_String (Resolved.Key);
      Dir  : constant String := Vault & "/synapse/" & Key;
      Text : Unbounded_String;
      Have : Boolean;
   begin
      Read (Env, Dir & "/Index.md", Text, Have);
      if not Have then
         Add
           (Into, "graph", Report.Warn,
            "no namespace at synapse/" & Key &
            "/ -- /synapse-init builds one");
         return;
      end if;
      declare
         Remote          : constant Core.Node_Query.Maybe_Text :=
           Core.Node_Query.Field (To_String (Text), "remote");
         Branch          : constant Core.Node_Query.Maybe_Text :=
           Core.Node_Query.Field (To_String (Text), "branch");
         Recorded_Remote : constant String                     :=
           (if Remote.Found then To_String (Remote.Value) else "");
         Recorded_Branch : constant String                     :=
           (if Branch.Found then To_String (Branch.Value) else "");
         Nodes           : Natural                             := 0;
      begin
         if Recorded_Remote = "" then
            Add
              (Into, "graph", Report.Fail,
               "Index.md has no remote field -- every component reads that " &
               "as a mismatch");
            return;
         end if;
         if Recorded_Remote /= To_String (Resolved.Remote) then
            Add
              (Into, "graph", Report.Fail,
               "remote mismatch: Index.md says " & Recorded_Remote &
               " -- rebuild with /synapse-rebuild-full if the remote " &
               "changed");
            return;
         end if;
         if Recorded_Branch /= To_String (Resolved.Branch_Key) then
            Add
              (Into, "graph", Report.Fail,
               "branch mismatch: Index.md says " & Recorded_Branch &
               ", this is " & To_String (Resolved.Branch_Key) &
               " -- the directory was renamed by hand");
            return;
         end if;

         declare
            Search : Ada.Directories.Search_Type;
            Item   : Ada.Directories.Directory_Entry_Type;
         begin
            Ada.Directories.Start_Search
              (Search, Dir, "*.md",
               [Ada.Directories.Ordinary_File => True, others => False]);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Item);
               if Ada.Directories.Simple_Name (Item) /= "Index.md" then
                  Nodes := Nodes + 1;
               end if;
            end loop;
            Ada.Directories.End_Search (Search);
         exception
            when others =>
               null;
         end;
         Add
           (Into, "graph", Report.Ok,
            "synapse/" & Key & "/ (" & Image.Image (Nodes) & " nodes)");
      end;
   end Namespace_Checks;

   ---------------------------------------------------------------------------
   --  The derived files: what the staleness hook, `symbol` and `callers`
   --  each need and say nothing about.
   ---------------------------------------------------------------------------

   function State_Of (Present : Boolean) return Report.Status is
     (if Present then Report.Ok else Report.Warn);

   procedure Work_Dir_Checks
     (Env      : Environment; Into : in out Checks;
      Resolved : Core.Identity.Resolved)
   is
      Found : constant Support.Maybe_Path :=
        Support.Work_Dir (Env, Prog, To_String (Resolved.Where.Repo_Root));
   begin
      if not Found.Found then
         return;
      end if;
      declare
         Work : constant String := To_String (Found.Value);
      begin
         Add (Into, "work dir", State_Of (Exists (Work)), Work);

         declare
            Index_Path : constant String := Work & "/_index.bin";
         begin
            if Exists (Index_Path) then
               declare
                  Map : Adapters.Index_Map.Map;
               begin
                  Adapters.Index_Map.Open (Map, Index_Path);
                  if Adapters.Index_Map.Discarded (Map) /=
                    Adapters.Index_Map.None
                  then
                     Add
                       (Into, "reverse index", Report.Fail,
                        "discarded (" &
                        Core.Fault_Names.Camel
                          (Adapters.Index_Map.Issue'Image
                             (Adapters.Index_Map.Discarded (Map))) &
                        ") -- rebuild it");
                  else
                     Add
                       (Into, "reverse index", Report.Ok,
                        Image.Image (Adapters.Index_Map.Count (Map)) &
                        " paths, " &
                        Image.Image (Adapters.Index_Map.Node_Count (Map)) &
                        " nodes, " &
                        Image.Image
                          (Adapters.Index_Map.Unassigned_Count (Map)) &
                        " unassigned");
                  end if;
               end;
            else
               --  The staleness hook's own precondition: without this file
               --  it does nothing at all.
               Add
                 (Into, "reverse index", Report.Warn,
                  "absent -- the staleness hook does nothing without it");
            end if;
         end;

         declare
            Cache : constant String := Work & "/_tags_cache.bin";
            Refs  : constant String := Work & "/_refs.tsv";
         begin
            Add
              (Into, "tags cache", State_Of (Exists (Cache)),
               (if Exists (Cache) then Cache
                else "absent -- `query symbol` will tag on demand, slowly"));
            Add
              (Into, "code cache", State_Of (Exists (Refs)),
               (if Exists (Refs) then Refs
                else "absent -- `callers` exits 1 until `build-refs` runs"));
         end;
      end;
   end Work_Dir_Checks;

   ---------------------------------------------------------------------------
   --  Grammar clone locks left behind. One nobody holds costs every later run
   --  its whole wait and then skips that extension, which shows only as
   --  tagging that stopped covering one language. A lock younger than the
   --  staleness window is the one that is not yet self-healing.
   ---------------------------------------------------------------------------

   procedure Grammar_Lock_Checks (Env : Environment; Into : in out Checks) is
      Named : constant Support.Maybe_Path          :=
        Adapters.Conf_Files.Resolve (Env.Vars.all, "SYNAPSE_GRAMMARS_DIR");
      Home  : constant Ports.Variables.Maybe_Value := Env.Vars.Get ("HOME");
   begin
      declare
         Repos                       : constant String            :=
           (if Named.Found then To_String (Named.Value) & "/repos"
            elsif Home.Found then
              To_String (Home.Value) & "/.cache/synapse/grammars/repos"
            else "");
         Search                      : Ada.Directories.Search_Type;
         Item                        : Ada.Directories.Directory_Entry_Type;
         Held, Abandoned             : Natural                    := 0;
         First_Held, First_Abandoned : Unbounded_String;
         Now : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      begin
         if Repos = "" or else not Exists (Repos) then
            return;
         end if;
         Ada.Directories.Start_Search
           (Search, Repos, "*.lock", [others => True]);
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Item);
            declare
               Path : constant String :=
                 Repos & "/" & Ada.Directories.Simple_Name (Item);
            begin
               if Now - Ada.Directories.Modification_Time (Path) >
                 Adapters.Tree_Sitter.Preparation.Lock_Stale_After
               then
                  Abandoned := Abandoned + 1;
                  if Length (First_Abandoned) = 0 then
                     First_Abandoned := To_Unbounded_String (Path);
                  end if;
               else
                  Held := Held + 1;
                  if Length (First_Held) = 0 then
                     First_Held := To_Unbounded_String (Path);
                  end if;
               end if;
            exception
               when others =>
                  null;
            end;
         end loop;
         Ada.Directories.End_Search (Search);

         if Held = 0 and then Abandoned = 0 then
            return;
         end if;
         if Held > 0 then
            Add
              (Into, "grammar locks", Report.Warn,
               Image.Image (Held) & " held (" & To_String (First_Held) & ")" &
               (if Abandoned > 0 then ", plus abandoned ones" else "") &
               " -- another synapse is cloning, or one was killed just now; " &
               "delete it if nothing is running");
         else
            Add
              (Into, "grammar locks", Report.Ok,
               Image.Image (Abandoned) & " abandoned (" &
               To_String (First_Abandoned) &
               ") -- older than the staleness window, so the next run takes " &
               "it over");
         end if;
      end;
   exception
      when others =>
         null;
   end Grammar_Lock_Checks;

   ---------------------------------------------------------------------------
   --  Whether the four hooks are registered once each in `settings.json`: a
   --  hook wired twice fires twice, and the only symptom is duplicated
   --  context nobody attributes to the settings.
   ---------------------------------------------------------------------------

   function Occurrences (Text, Needle : String) return Natural is
      Found : Natural  := 0;
      Pos   : Positive := Text'First;
   begin
      while Pos + Needle'Length - 1 <= Text'Last loop
         if Text (Pos .. Pos + Needle'Length - 1) = Needle then
            Found := Found + 1;
            Pos   := Pos + Needle'Length;
         else
            Pos := Pos + 1;
         end if;
      end loop;
      return Found;
   end Occurrences;

   Session_Start  : aliased constant String := "session-start";
   Prompt_Context : aliased constant String := "prompt-context";
   Staleness      : aliased constant String := "staleness";
   Stop_Nudge     : aliased constant String := "stop-nudge";

   Hook_Names : constant array (1 .. 4) of access constant String :=
     [Session_Start'Access, Prompt_Context'Access, Staleness'Access,
     Stop_Nudge'Access];

   procedure Hook_Checks (Env : Environment; Into : in out Checks) is
      Home : constant Ports.Variables.Maybe_Value := Env.Vars.Get ("HOME");
   begin
      if not Home.Found then
         return;
      end if;
      declare
         Path : constant String :=
           To_String (Home.Value) & "/.claude/settings.json";
         Text : Unbounded_String;
         Have : Boolean;
      begin
         Read (Env, Path, Text, Have);
         if not Have then
            Add
              (Into, "hooks", Report.Fail,
               "no settings.json -- run `synapse-setup configure claude`");
            return;
         end if;
         declare
            Whole      : constant String := To_String (Text);
            Missing    : Natural         := 0;
            Duplicated : Natural         := 0;
         begin
            for Which in Hook_Names'Range loop
               declare
                  N : constant Natural :=
                    Occurrences
                      (Whole, "synapse-hook " & Hook_Names (Which).all);
               begin
                  if N = 0 then
                     Missing := Missing + 1;
                  end if;
                  if N > 1 then
                     Duplicated := Duplicated + 1;
                  end if;
               end;
            end loop;
            if Missing = 0 and then Duplicated = 0 then
               Add (Into, "hooks", Report.Ok, "all four registered once");
            elsif Duplicated /= 0 then
               Add
                 (Into, "hooks", Report.Fail,
                  Image.Image (Duplicated) &
                  " registered more than once -- each fires that many " &
                  "times; fix ~/.claude/settings.json or re-run " &
                  "`synapse-setup configure claude`");
            else
               Add
                 (Into, "hooks", Report.Fail,
                  Image.Image (Missing) &
                  " of 4 not registered -- run `synapse-setup configure " &
                  "claude`");
            end if;
            --  A wrapper still named would take precedence over the binary
            --  for that hook, and keep working.
            if Occurrences (Whole, "hooks/synapse-") > 0 then
               Add
                 (Into, "hook wiring", Report.Fail,
                  "settings.json still names a hooks/*.sh wrapper -- fix " &
                  "~/.claude/settings.json or re-run `synapse-setup " &
                  "configure claude`");
            end if;
         end;
      end;
   end Hook_Checks;

   function Diagnose (Env : Environment; Repo : String) return Exit_Code is
      Into                : Checks;
      Vault               : Unbounded_String;
      Have_Vault, Have_Id : Boolean;
      Resolved            : Core.Identity.Resolved;
   begin
      Dependencies (Env, Into);
      Vault_Checks (Env, Into, Vault, Have_Vault);
      Identity_Checks (Into, Repo, Resolved, Have_Id);
      if Have_Vault and then Have_Id then
         Namespace_Checks (Env, Into, To_String (Vault), Resolved);
      end if;
      if Have_Id then
         Work_Dir_Checks (Env, Into, Resolved);
      end if;
      Grammar_Lock_Checks (Env, Into);
      Hook_Checks (Env, Into);
      Say (Env, Report.Report (Into.Items));
      return Report.Exit_Code (Into.Items);
   end Diagnose;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Repo : Unbounded_String := To_Unbounded_String (".");
      I    : Positive         := 1;
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
            elsif Arg = "--repo" then
               Cli_Args.Take_Value (Args, I, Value, Found);
               if not Found then
                  return Usage_Error (Env, Usage_Text);
               end if;
               Repo := Value;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
         I := I + 1;
      end loop;
      return Diagnose (Env, To_String (Repo));
   end Run;

end Synapse.Commands.Doctor;
