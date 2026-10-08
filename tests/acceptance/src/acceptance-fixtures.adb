with Ada.Calendar;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

with AUnit.Assertions;

with GNAT.OS_Lib;

with Synapse.Adapters.System_Process;

package body Acceptance.Fixtures is

   package Env renames Ada.Environment_Variables;
   package Runner renames Synapse.Adapters.System_Process;

   LF : constant Character := Character'Val (10);

   --  Where the suite was started: the checkout, so that `bin/` and
   --  `packages/` are below it.
   Start_Dir : constant String := Ada.Directories.Current_Directory;

   Counter : Natural := 0;

   function Image (N : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Left));

   function Checkout return String is (Start_Dir);

   function Synapse_Bin return String is (Start_Dir & "/bin/synapse");

   function Synapse_Fake_Bin return String is
     (Start_Dir & "/bin/synapse-fake");

   function Hook_Bin return String is (Start_Dir & "/bin/synapse-hook");

   Fake_Bin_Dir : constant String :=
     Start_Dir & "/tests/acceptance/fixtures/fake-bin";

   ---------------------------------------------------------------------------
   --  Text
   ---------------------------------------------------------------------------

   function Contains (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Trim (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last
        and then Text (First) in
          ' ' | Character'Val (9) | LF | Character'Val (13)
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then Text (Last) in
          ' ' | Character'Val (9) | LF | Character'Val (13)
      loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trim;

   function Both (R : Result) return String is
     ("stdout: " & To_String (R.Output) & LF & "stderr: " &
      To_String (R.Errors));

   procedure Assert_Exit (R : Result; Want : Integer; What : String) is
   begin
      AUnit.Assertions.Assert
        (R.Exit_Code = Want,
         What & ": exit" & Integer'Image (R.Exit_Code) & ", wanted" &
         Integer'Image (Want) & LF & Both (R));
   end Assert_Exit;

   procedure Assert_Contains (Text, Needle, What : String) is
   begin
      AUnit.Assertions.Assert
        (Contains (Text, Needle),
         What & ": no <" & Needle & "> in" & LF & Text);
   end Assert_Contains;

   procedure Assert_Lacks (Text, Needle, What : String) is
   begin
      AUnit.Assertions.Assert
        (not Contains (Text, Needle),
         What & ": unexpected <" & Needle & "> in" & LF & Text);
   end Assert_Lacks;

   procedure Assert_Equal (Got, Want, What : String) is
   begin
      AUnit.Assertions.Assert
        (Got = Want, What & ": got <" & Got & ">, wanted <" & Want & ">");
   end Assert_Equal;

   ---------------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------------

   procedure Write_File (Path, Text : String) is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path));
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Path);
      String'Write (Ada.Streams.Stream_IO.Stream (File), Text);
      Ada.Streams.Stream_IO.Close (File);
   end Write_File;

   function Read_File (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      declare
         Size : constant Natural :=
           Natural (Ada.Streams.Stream_IO.Size (File));
         Text : String (1 .. Size);
      begin
         String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
         Ada.Streams.Stream_IO.Close (File);
         return Text;
      end;
   end Read_File;

   function Exists (Path : String) return Boolean is
     (Ada.Directories.Exists (Path));

   procedure Delete_File (Path : String) is
   begin
      Ada.Directories.Delete_File (Path);
   end Delete_File;

   Starting_Home : constant String :=
     (if Env.Exists ("HOME") then Env.Value ("HOME") else "");

   function Real_Home return String is (Starting_Home);

   procedure Make_Executable (Path : String) is
   begin
      GNAT.OS_Lib.Set_Executable (Path);
   end Make_Executable;

   procedure Delete_Tree (Path : String) is
   begin
      Ada.Directories.Delete_Tree (Path);
   end Delete_Tree;

   procedure Make_Dir (Path : String) is
   begin
      Ada.Directories.Create_Path (Path);
   end Make_Dir;

   function Files_In
     (Dir : String; Suffix : String := "")
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      Ada.Directories.Start_Search
        (Search, Dir, "",
         [Ada.Directories.Ordinary_File => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name'Length >= Suffix'Length
              and then Name (Name'Last - Suffix'Length + 1 .. Name'Last) =
                Suffix
            then
               Result.Append (To_Unbounded_String (Name));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      return Result;
   end Files_In;

   function Lines (Text : String) return Synapse.Core.Text_Lists.Vector is
      Result : Synapse.Core.Text_Lists.Vector;
      Start  : Positive := Text'First;
   begin
      for I in Text'Range loop
         if Text (I) = LF then
            Result.Append (To_Unbounded_String (Text (Start .. I - 1)));
            Start := I + 1;
         end if;
      end loop;
      if Start <= Text'Last then
         Result.Append (To_Unbounded_String (Text (Start .. Text'Last)));
      end if;
      return Result;
   end Lines;

   function Has_Line (Text, Line : String) return Boolean is
   begin
      for Item of Lines (Text) loop
         if To_String (Item) = Line then
            return True;
         end if;
      end loop;
      return False;
   end Has_Line;

   function Has_Line_Starting (Text, Prefix : String) return Boolean is
   begin
      for Item of Lines (Text) loop
         if Starts_With (To_String (Item), Prefix) then
            return True;
         end if;
      end loop;
      return False;
   end Has_Line_Starting;

   function Prose_Before_Sources (Text : String) return String is
      Result : Unbounded_String;
   begin
      for Item of Lines (Text) loop
         exit when To_String (Item) = "## Sources";
         Append (Result, Item);
         Append (Result, LF);
      end loop;
      return To_String (Result);
   end Prose_Before_Sources;

   function Root (F : Fixture) return String is (To_String (F.Root_Dir));

   function Repo (F : Fixture) return String is (Root (F) & "/repo");

   function Vault (F : Fixture) return String is (Root (F) & "/vault");

   function Work (F : Fixture) return String is (Root (F) & "/work");

   function Home (F : Fixture) return String is (Root (F) & "/home");

   procedure Write_Repo_File (F : Fixture; Name, Text : String) is
   begin
      Write_File (Repo (F) & "/" & Name, Text);
   end Write_Repo_File;

   procedure Write_Work_File (F : Fixture; Name, Text : String) is
   begin
      Write_File (Work (F) & "/" & Name, Text);
   end Write_Work_File;

   procedure Write_Root_File (F : Fixture; Name, Text : String) is
   begin
      Write_File (Root (F) & "/" & Name, Text);
   end Write_Root_File;

   ---------------------------------------------------------------------------
   --  Environment
   ---------------------------------------------------------------------------

   --  Remembers what a variable was, once, so that Finalize can put it back.
   procedure Remember (F : in out Fixture; Name : String) is
   begin
      for Item of F.Changed loop
         if To_String (Item.Name) = Name then
            return;
         end if;
      end loop;
      F.Changed.Append
        (Saved'
           (Name => To_Unbounded_String (Name), Had => Env.Exists (Name),
            Old  =>
              To_Unbounded_String
                (if Env.Exists (Name) then Env.Value (Name) else "")));
   end Remember;

   procedure Set_Env (F : in out Fixture; Name, Value : String) is
   begin
      Remember (F, Name);
      Env.Set (Name, Value);
   end Set_Env;

   procedure Unset_Env (F : in out Fixture; Name : String) is
   begin
      Remember (F, Name);
      if Env.Exists (Name) then
         Env.Clear (Name);
      end if;
   end Unset_Env;

   procedure Keep_Only_Path (F : in out Fixture) is
      Names : Synapse.Core.Text_Lists.Vector;

      procedure Collect (Name, Value : String) is
         pragma Unreferenced (Value);
      begin
         if Name /= "PATH" then
            Names.Append (To_Unbounded_String (Name));
         end if;
      end Collect;
   begin
      Env.Iterate (Collect'Access);
      for Name of Names loop
         Unset_Env (F, To_String (Name));
      end loop;
   end Keep_Only_Path;

   procedure Use_Schema_Content_Root (F : in out Fixture) is
      Content : constant String := Root (F) & "/content";
   begin
      Write_File
        (Content & "/schema/graph-node/v1.yaml",
         Read_File
           (Start_Dir & "/packages/synapse/schema/graph-node/v1.yaml"));
      Set_Env (F, "SYNAPSE_CONTENT_ROOT", Content);
   end Use_Schema_Content_Root;

   ---------------------------------------------------------------------------
   --  Lifetime
   ---------------------------------------------------------------------------

   --  The variables that name the identity of a checkout, which a shell that
   --  runs the suite may export.
   procedure Remove_Inherited (F : in out Fixture) is
      Names : Synapse.Core.Text_Lists.Vector;

      procedure Collect (Name, Value : String) is
         pragma Unreferenced (Value);
      begin
         if Name'Length >= 8
           and then Name (Name'First .. Name'First + 7) = "SYNAPSE_"
         then
            Names.Append (To_Unbounded_String (Name));
         end if;
      end Collect;
   begin
      Env.Iterate (Collect'Access);
      for Name of Names loop
         Unset_Env (F, To_String (Name));
      end loop;
      Unset_Env (F, "CLAUDE_PLUGIN_ROOT");
      Unset_Env (F, "XDG_CONFIG_HOME");
   end Remove_Inherited;

   overriding procedure Initialize (F : in out Fixture) is
      Stamp : constant Natural :=
        Natural (Ada.Calendar.Seconds (Ada.Calendar.Clock) * 1_000.0);
   begin
      Counter    := Counter + 1;
      F.Root_Dir :=
        To_Unbounded_String
          ("/tmp/synapse-it-" & Image (Stamp) & "-" & Image (Counter));
      Ada.Directories.Create_Path (Root (F) & "/repo");
      Ada.Directories.Create_Path (Root (F) & "/vault");
      Ada.Directories.Create_Path (Root (F) & "/work");
      Ada.Directories.Create_Path (Root (F) & "/home/.claude");
      Remove_Inherited (F);
      Set_Env (F, "GIT_CEILING_DIRECTORIES", "/tmp");
      Set_Env (F, "HOME", Home (F));
      Set_Env (F, "SYNAPSE_VAULT_DIR", Vault (F));
      Set_Env
        (F, "PATH",
         Fake_Bin_Dir & ":" &
         (if Env.Exists ("PATH") then Env.Value ("PATH")
          else "/usr/bin:/bin"));
   end Initialize;

   overriding procedure Finalize (F : in out Fixture) is
   begin
      for Item of reverse F.Changed loop
         if Item.Had then
            Env.Set (To_String (Item.Name), To_String (Item.Old));
         elsif Env.Exists (To_String (Item.Name)) then
            Env.Clear (To_String (Item.Name));
         end if;
      end loop;
      F.Changed.Clear;
      if Length (F.Root_Dir) > 0 then
         Ada.Directories.Delete_Tree (Root (F));
      end if;
   exception
      when others =>
         null;
   end Finalize;

   ---------------------------------------------------------------------------
   --  Running programs
   ---------------------------------------------------------------------------

   function Args
     (A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12 : String := "")
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
      Items  : constant array (1 .. 12) of access constant String :=
        [A1'Unrestricted_Access, A2'Unrestricted_Access,
        A3'Unrestricted_Access, A4'Unrestricted_Access, A5'Unrestricted_Access,
        A6'Unrestricted_Access, A7'Unrestricted_Access, A8'Unrestricted_Access,
        A9'Unrestricted_Access, A10'Unrestricted_Access,
        A11'Unrestricted_Access, A12'Unrestricted_Access];
   begin
      for Item of Items loop
         if Item.all /= "" then
            Result.Append (To_Unbounded_String (Item.all));
         end if;
      end loop;
      return Result;
   end Args;

   function Run
     (F   : Fixture; Program : String; Argv : Synapse.Core.Text_Lists.Vector;
      Cwd : String; Stdin : String := ""; Piped : Boolean := False)
      return Result
   is
      pragma Unreferenced (F);
      R : Runner.System_Runner;
   begin
      return
        R.Run
          (Program, Argv,
           (Cwd   => To_Unbounded_String (Cwd), Has_Stdin => Piped,
            Stdin => To_Unbounded_String (Stdin)));
   end Run;

   task body Runner_Task is
      Command         : Unbounded_String;
      Params          : Synapse.Core.Text_Lists.Vector;
      Where           : Unbounded_String;
      Outcome         : Result;
      Runner_Instance : Runner.System_Runner;
   begin
      accept Start
        (Program : String; Argv : Synapse.Core.Text_Lists.Vector; Cwd : String)
      do
         Command := To_Unbounded_String (Program);
         Params  := Argv;
         Where   := To_Unbounded_String (Cwd);
      end Start;
      Outcome :=
        Runner_Instance.Run
          (To_String (Command), Params, (Cwd => Where, others => <>));
      accept Finish (R : out Result) do
         R := Outcome;
      end Finish;
   end Runner_Task;

   procedure Start
     (B    : in out Background; Program : String;
      Argv :        Synapse.Core.Text_Lists.Vector; Cwd : String)
   is
   begin
      B.Job.Start (Program, Argv, Cwd);
   end Start;

   function Await (B : in out Background) return Result is
      R : Result;
   begin
      B.Job.Finish (R);
      return R;
   end Await;

   function Run_Synapse
     (F                                        : Fixture; A1 : String;
      A2, A3, A4, A5, A6, A7, A8, A9, A10, A11 : String := "") return Result is
     (Run
        (F, Synapse_Bin, Args (A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11),
         Repo (F)));

   function Run_Fake
     (F                                        : Fixture; A1 : String;
      A2, A3, A4, A5, A6, A7, A8, A9, A10, A11 : String := "") return Result is
     (Run
        (F, Synapse_Fake_Bin,
         Args (A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11), Repo (F)));

   function Run_Hook
     (F                                        : Fixture; A1 : String;
      A2, A3, A4, A5, A6, A7, A8, A9, A10, A11 : String := "") return Result is
     (Run
        (F, Hook_Bin, Args (A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11),
         Repo (F)));

   function Run_Synapse_Outside_Repo
     (F : Fixture; A1 : String; A2, A3, A4, A5, A6 : String := "")
      return Result is
     (Run (F, Synapse_Bin, Args (A1, A2, A3, A4, A5, A6), Root (F)));

   function Run_Synapse_List
     (F : Fixture; Argv : Synapse.Core.Text_Lists.Vector) return Result is
     (Run (F, Synapse_Bin, Argv, Repo (F)));

   function Run_Fake_List
     (F : Fixture; Argv : Synapse.Core.Text_Lists.Vector) return Result is
     (Run (F, Synapse_Fake_Bin, Argv, Repo (F)));

   function Run_Hook_Stdin
     (F : Fixture; Stdin : String; A1 : String; A2, A3, A4 : String := "")
      return Result is
     (Run (F, Hook_Bin, Args (A1, A2, A3, A4), Repo (F), Stdin, True));

   function Run_Fake_Stdin
     (F                  : Fixture; Stdin : String; A1 : String;
      A2, A3, A4, A5, A6 : String := "") return Result is
     (Run
        (F, Synapse_Fake_Bin, Args (A1, A2, A3, A4, A5, A6), Repo (F), Stdin,
         True));

   ---------------------------------------------------------------------------
   --  Git
   ---------------------------------------------------------------------------

   function Git
     (F : Fixture; A1 : String; A2, A3, A4, A5, A6, A7, A8 : String := "")
      return Result is
     (Run (F, "git", Args (A1, A2, A3, A4, A5, A6, A7, A8), Repo (F)));

   function Git_Output
     (F : Fixture; A1 : String; A2, A3, A4, A5, A6 : String := "")
      return String is
     (Trim (To_String (Git (F, A1, A2, A3, A4, A5, A6).Output)));

   procedure Git_Commit (F : Fixture; Message : String) is
      Ignore : Result;
   begin
      Ignore := Git (F, "init", "-q", "-b", "main");
      Ignore := Git (F, "add", "-A");
      Ignore :=
        Git
          (F, "-c", "user.email=test@test", "-c", "user.name=test", "commit",
           "-q", "-m", Message);
   end Git_Commit;

   procedure Commit_All (F : Fixture; Message : String) is
      Ignore : Result;
   begin
      Ignore := Git (F, "add", "-A");
      Ignore :=
        Git
          (F, "-c", "user.email=test@test", "-c", "user.name=test", "commit",
           "-q", "-m", Message);
   end Commit_All;

   procedure Make_Repo (F : Fixture; Remote : String := "") is
      Ignore : Result;
   begin
      Write_Repo_File (F, "src/foo.aa", "let x = 1" & LF);
      Git_Commit (F, "init");
      if Remote /= "" then
         Ignore := Git (F, "remote", "add", "origin", Remote);
      end if;
   end Make_Repo;

   ---------------------------------------------------------------------------
   --  Namespaces
   ---------------------------------------------------------------------------

   function Repo_Name (F : Fixture) return String is
     (Trim (To_String (Run_Fake (F, "namespace", "--repo", Repo (F)).Output)));

   function Ns_Repo (F : Fixture) return String is
      Name : constant String := Repo_Name (F);
   begin
      for I in reverse Name'Range loop
         if Name (I) = '@' then
            return Name (Name'First .. I - 1);
         end if;
      end loop;
      return Name;
   end Ns_Repo;

   function Ns_Branch (F : Fixture) return String is
      Name : constant String := Repo_Name (F);
   begin
      for I in reverse Name'Range loop
         if Name (I) = '@' then
            return Name (I + 1 .. Name'Last);
         end if;
      end loop;
      return "";
   end Ns_Branch;

   function Repo_Remote_Or_Path (F : Fixture) return String is
      Remote : constant Result := Git (F, "remote", "get-url", "origin");
   begin
      if Remote.Exit_Code = 0 then
         return Trim (To_String (Remote.Output));
      end if;
      return Git_Output (F, "rev-parse", "--show-toplevel");
   end Repo_Remote_Or_Path;

   function Default_Work_Dir (F : Fixture) return String is
     (Home (F) & "/.cache/synapse/work/" & Repo_Name (F));

   procedure Write_Synapse_Index (F : Fixture; Namespace, Remote : String) is
      Branch  : constant String :=
        Trim
          (To_String
             (Run_Fake (F, "namespace", "--repo", Repo (F), "--branch")
                .Output));
      At_Sign : Natural         := Namespace'Last + 1;
   begin
      for I in reverse Namespace'Range loop
         if Namespace (I) = '@' then
            At_Sign := I;
            exit;
         end if;
      end loop;
      Write_File
        (Vault (F) & "/synapse/" & Namespace & "/Index.md",
         "---" & LF & "title: """ & Namespace & " " & Dash &
         " Synapse index""" & LF & "node_type: synapse-index" & LF &
         "project: " & Namespace (Namespace'First .. At_Sign - 1) & LF &
         "branch: " & Branch & LF & "remote: """ & Remote & """" & LF &
         "built_at: ""test""" & LF & "---" & LF & "# " & Namespace & " " &
         Dash & " Synapse index" & LF);
   end Write_Synapse_Index;

   procedure Write_Index_Bin (F : Fixture; Work_Dir, Pairs : String) is
      Unassigned : constant String := Work_Dir & "/.unassigned-fixture";
      R          : Result;
   begin
      Write_File (Unassigned, "");
      R :=
        Run
          (F, Synapse_Fake_Bin,
           Args
             ("index", "build", "--unassigned", Unassigned, "--out",
              Work_Dir & "/_index.bin"),
           Repo (F), Pairs, True);
      if R.Exit_Code /= 0 then
         raise Program_Error with "index build failed: " & Both (R);
      end if;
      Ada.Directories.Delete_File (Unassigned);
   end Write_Index_Bin;

end Acceptance.Fixtures;
