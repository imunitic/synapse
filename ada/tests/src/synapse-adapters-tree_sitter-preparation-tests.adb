with Ada.Calendar;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.OS_Lib;

with AUnit.Assertions;
with Synapse.Adapters.Dynamic_Libraries;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.System_Process;
with Synapse.Core.Text_Lists;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Tree_Sitter.Preparation.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Build_Results;
   use Clone_Results;
   use Synapse.Test_Scratch;
   use type Ada.Calendar.Time;
   use type Grammar.Load_Error;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Real_Runner : Adapters.System_Process.System_Runner;
   Loader      : Dynamic_Libraries.System_Loader;

   No_Text : constant Core.Grammar_Registry.Maybe_Text := (Found => False);

   function Set_To (Text : String) return Core.Grammar_Registry.Maybe_Text is
     (Found => True, Value => To_Unbounded_String (Text));

   function Contains (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Reason (Result : Build_Result) return String is
     (if Is_Success (Result) then "" else Describe (Error (Result)));

   --  Builds and fails the test with the reason when it does not.
   procedure Build_Ok
     (Run : in out Runner.Runner'Class; Repo_Dir : String; Out_Path : String;
      Max_Tries :        Positive := Default_Lock_Tries)
   is
      Result : constant Build_Result :=
        Build (Run, Repo_Dir, Out_Path, Max_Tries);
   begin
      Assert (Is_Success (Result), "the build: " & Reason (Result));
   end Build_Ok;

   function Fails_With
     (Result : Build_Result; Kind : Failure_Kind) return Boolean is
     (not Is_Success (Result) and then Error (Result).Kind = Kind);

   function Detail (Result : Build_Result) return String is
     (if Is_Success (Result) then "" else To_String (Error (Result).Detail));

   --  The clone's directory, or a failed assertion with the reason.
   function Cloned
     (Run       : in out Runner.Runner'Class; Url : String; Parent : String;
      Max_Tries :        Positive := Default_Lock_Tries) return String
   is
      Result : constant Clone_Result :=
        Ensure_Cloned (Run, Url, Parent, Max_Tries);
   begin
      Assert
        (Is_Success (Result),
         "the clone: " &
         (if Is_Success (Result) then "" else Describe (Error (Result))));
      return (if Is_Success (Result) then To_String (Value (Result)) else "");
   end Cloned;

   function Clone_Fails_With
     (Result : Clone_Result; Kind : Failure_Kind) return Boolean is
     (not Is_Success (Result) and then Error (Result).Kind = Kind);

   --  Moves a file's or directory's modification time to Ago seconds before
   --  now, or after it when negative. Whether the operating system reads the
   --  fields it is given as local or as UTC differs between systems, so the
   --  result is read back and the request corrected once.
   procedure Set_Modified (Path : String; Ago : Duration) is
      Target     : constant Ada.Calendar.Time := Ada.Calendar.Clock - Ago;
      Correction : Duration                   := 0.0;

      procedure Set_To_Fields_Of (Moment : Ada.Calendar.Time) is
         Year    : Ada.Calendar.Year_Number;
         Month   : Ada.Calendar.Month_Number;
         Day     : Ada.Calendar.Day_Number;
         Seconds : Ada.Calendar.Day_Duration;
         Whole   : Natural;
      begin
         Ada.Calendar.Split (Moment, Year, Month, Day, Seconds);
         Whole := Natural (Seconds - 0.5);
         GNAT.OS_Lib.Set_File_Last_Modify_Time_Stamp
           (Path,
            GNAT.OS_Lib.GM_Time_Of
              (Year, Month, Day, Whole / 3_600, (Whole mod 3_600) / 60,
               Whole mod 60));
      end Set_To_Fields_Of;
   begin
      for Pass in 1 .. 2 loop
         Set_To_Fields_Of (Target - Correction);
         Correction :=
           Correction + (Ada.Directories.Modification_Time (Path) - Target);
      end loop;
   end Set_Modified;

   --  A grammar the tests can compile: the fake3 fixture's sources.
   procedure Copy_Grammar (To_Dir : String) is
      Fixture : constant String := "fixtures/fake3/src";
   begin
      Ada.Directories.Create_Path (To_Dir & "/src/tree_sitter");
      Ada.Directories.Copy_File
        (Fixture & "/parser.c", To_Dir & "/src/parser.c");
      Ada.Directories.Copy_File
        (Fixture & "/tree_sitter/alloc.h",
         To_Dir & "/src/tree_sitter/alloc.h");
      Ada.Directories.Copy_File
        (Fixture & "/tree_sitter/array.h",
         To_Dir & "/src/tree_sitter/array.h");
      Ada.Directories.Copy_File
        (Fixture & "/tree_sitter/parser.h",
         To_Dir & "/src/tree_sitter/parser.h");
   end Copy_Grammar;

   function Library_In (Dir : Scratch; Name : String) return String is
     (Path (Dir, "out/" & Name & "." & Loader.Extension));

   --  Answers from a script and records every command.
   type Scripted_Runner is limited new Runner.Runner with record
      Log        : Unbounded_String;
      --  Which of zig, cc, gcc and clang report a version.
      Have       : String (1 .. 4) := "nnnn";
      --  Which of them then compile: y, or n for a failure with a message.
      Compiles   : String (1 .. 4) := "nnnn";
      Cannot_Run : Boolean         := False;
      --  Compile errors that run to hundreds of characters.
      Verbose    : Boolean         := False;
   end record;

   function Slot (Program : String) return Natural is
     (if Program = "zig" then 1 elsif Program = "cc" then 2
      elsif Program = "gcc" then 3 elsif Program = "clang" then 4 else 0);

   overriding function Run
     (R    : in out Scripted_Runner; Program : String;
      Args :        Core.Text_Lists.Vector; Opts : Runner.Options)
      return Runner.Result
   is
      Line   : Unbounded_String := To_Unbounded_String (Program);
      Result : Runner.Result;
      Which  : constant Natural := Slot (Program);
   begin
      if R.Cannot_Run then
         raise Runner.Process_Failure with Program;
      end if;
      for A of Args loop
         Append (Line, " " & To_String (A));
      end loop;
      Append (R.Log, To_String (Line) & "|" & To_String (Opts.Cwd) & LF);
      if Which = 0 then
         return Result;
      end if;
      if To_String (Args (1)) in "--version" | "version" then
         Result.Exit_Code := (if R.Have (Which) = 'y' then 0 else 127);
      elsif R.Compiles (Which) /= 'y' then
         Result.Exit_Code := 1;
         Result.Errors    :=
           To_Unbounded_String
             ("cannot compile with " & Program &
              (if R.Verbose then " " & [1 .. 400 => 'e'] else "") & LF);
      end if;
      return Result;
   end Run;

   ---------------------------------------------------------------------------
   --  Building with real compilers
   ---------------------------------------------------------------------------

   procedure A_Grammar_Compiles_Into_A_Directory_That_Does_Not_Exist_Yet
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir      : constant Scratch := Make;
      Out_Path : constant String  := Library_In (Dir, "fake");
   begin
      Copy_Grammar (Path (Dir, "g"));
      Assert
        (not Ada.Directories.Exists (Path (Dir, "out")),
         "the output directory is not there yet");
      Build_Ok (Real_Runner, Path (Dir, "g"), Out_Path);
      Assert (Ada.Directories.Exists (Out_Path), "built");
      Assert
        (not Ada.Directories.Exists (Out_Path & ".lock"),
         "no lock left behind");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Grammar_Compiles_Into_A_Directory_That_Does_Not_Exist_Yet;

   procedure A_Compiled_Grammar_Loads_And_An_Unknown_Symbol_Does_Not
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Resolved;
   begin
      Copy_Grammar (Path (Dir, "g"));
      Got :=
        Resolve_And_Load
          (Real_Runner, Loader, Path (Dir, "g"), Path (Dir, "cache"),
           "tree-sitter-fake3", No_Text, No_Text);
      Assert
        (Got.Kind = Loaded, "the symbol derived from the repository name");
      Assert
        (Ada.Directories.Exists
           (Library_Path (Loader, Path (Dir, "cache"), "tree_sitter_fake3")),
         "kept under its symbol");
      Got :=
        Resolve_And_Load
          (Real_Runner, Loader, Path (Dir, "g"), Path (Dir, "cache"),
           "tree-sitter-fake3", No_Text, Set_To ("tree_sitter_absent"));
      Assert
        (Got.Kind = Not_Loadable and then Got.Error = Grammar.Symbol_Not_Found,
         "a symbol the library has not");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Compiled_Grammar_Loads_And_An_Unknown_Symbol_Does_Not;

   procedure A_Grammar_In_A_Subdirectory_Loads_By_Its_Explicit_Symbol
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Got : Resolved;
   begin
      Copy_Grammar (Path (Dir, "repo/grammars/inner"));
      Got :=
        Resolve_And_Load
          (Real_Runner, Loader, Path (Dir, "repo"), Path (Dir, "cache"),
           "tree-sitter-other", Set_To ("grammars/inner"),
           Set_To ("tree_sitter_fake3"));
      Assert
        (Got.Kind = Loaded, "the parser under the sub-path, the symbol given");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Grammar_In_A_Subdirectory_Loads_By_Its_Explicit_Symbol;

   procedure Building_Again_Does_Nothing_Until_A_Source_Is_Newer
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir      : constant Scratch := Make;
      Out_Path : constant String  := Library_In (Dir, "fake");
      Scanner  : constant String  := Path (Dir, "g/src/scanner.c");
      Built    : Ada.Calendar.Time;
   begin
      Copy_Grammar (Path (Dir, "g"));
      File_Bytes.Write (Scanner, "int fake_scan (void) { return 1; }" & LF);
      Build_Ok (Real_Runner, Path (Dir, "g"), Out_Path);
      Built := Ada.Directories.Modification_Time (Out_Path);

      delay 1.1;
      Build_Ok (Real_Runner, Path (Dir, "g"), Out_Path);
      Assert
        (Ada.Directories.Modification_Time (Out_Path) = Built,
         "up to date: nothing is compiled");

      --  Only the scanner moves, to after the library; the parser stays older.
      Set_Modified (Scanner, -5.0);
      Build_Ok (Real_Runner, Path (Dir, "g"), Out_Path);
      Assert
        (Ada.Directories.Modification_Time (Out_Path) > Built,
         "a scanner newer than the library rebuilds it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Building_Again_Does_Nothing_Until_A_Source_Is_Newer;

   procedure A_Tree_With_No_Parser_Is_Refused_Not_Compiled_Into_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch      := Make;
      Result : constant Build_Result :=
        Build (Real_Runner, Path (Dir), Library_In (Dir, "none"));
   begin
      Assert (Fails_With (Result, Parser_Source_Missing), "refused");
      Assert
        (not Ada.Directories.Exists (Library_In (Dir, "none")),
         "nothing built");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Tree_With_No_Parser_Is_Refused_Not_Compiled_Into_Nothing;

   procedure A_Scanner_In_Another_Language_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Copy_Grammar (Path (Dir, "g"));
      File_Bytes.Write (Path (Dir, "g/src/scanner.cc"), "int x;" & LF);
      Assert
        (Fails_With
           (Build (Real_Runner, Path (Dir, "g"), Library_In (Dir, "x")),
            Compile_Failed),
         "refused");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Scanner_In_Another_Language_Is_Refused;

   procedure Source_That_Does_Not_Compile_Names_Every_Compiler_That_Failed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      Result : Build_Result;
   begin
      Ada.Directories.Create_Path (Path (Dir, "g/src"));
      File_Bytes.Write (Path (Dir, "g/src/parser.c"), "this is not C;" & LF);
      Result := Build (Real_Runner, Path (Dir, "g"), Library_In (Dir, "bad"));
      Assert (Fails_With (Result, Compile_Failed), "refused");
      Assert
        (Contains (Detail (Result), "failed with every compiler found"),
         "says what happened");
      Assert
        (not Ada.Directories.Exists (Library_In (Dir, "bad") & ".lock"),
         "the lock is released after a failed compile");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Source_That_Does_Not_Compile_Names_Every_Compiler_That_Failed;

   ---------------------------------------------------------------------------
   --  Building with scripted compilers
   ---------------------------------------------------------------------------

   function Source_Tree (Dir : Scratch) return String is
   begin
      Ada.Directories.Create_Path (Path (Dir, "g/src"));
      File_Bytes.Write (Path (Dir, "g/src/parser.c"), "int x;" & LF);
      return Path (Dir, "g");
   end Source_Tree;

   procedure Every_Compiler_Found_Gets_An_Attempt_In_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      R   : Scripted_Runner;
   begin
      R.Have     := "nyyy";
      R.Compiles := "nnyn";
      Build_Ok (R, Source_Tree (Dir), Library_In (Dir, "x"));
      declare
         Log : constant String := To_String (R.Log);
      begin
         Assert
           (Contains (Log, "cc --version")
            and then Contains (Log, "gcc --version"),
            "found by asking for a version");
         Assert
           (Contains (Log, "cc -shared -fPIC -O2 -I")
            and then Contains (Log, "gcc -shared -fPIC -O2 -I"),
            "the flags: loadable, optimised, the source directory");
         Assert
           (Contains (Log, "-o " & Library_In (Dir, "x"))
            and then Contains (Log, "/src/parser.c"),
            "the output and the parser");
         Assert (not Contains (Log, "-march"), "nothing machine specific");
         Assert
           (not Contains (Log, "clang -shared"),
            "the third is not tried once one works");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Every_Compiler_Found_Gets_An_Attempt_In_Order;

   procedure A_Compiler_That_Reports_A_Version_But_Cannot_Compile_Is_Skipped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      R      : Scripted_Runner;
      Result : Build_Result;
   begin
      R.Have     := "nnyy";
      R.Compiles := "nynn";
      Result     := Build (R, Source_Tree (Dir), Library_In (Dir, "x"));
      Assert
        (Fails_With (Result, Compile_Failed), "all that were found failed");
      Assert
        (Contains (Detail (Result), "gcc: cannot compile with gcc")
         and then Contains
           (Detail (Result), "clang: cannot compile with clang"),
         "what each said");
      Assert
        (not Contains
           (Detail (Result), "cc: cannot compile with cc" & LF & "  gcc"),
         "one that is not there is not blamed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Compiler_That_Reports_A_Version_But_Cannot_Compile_Is_Skipped;

   procedure Zig_Cc_Is_Tried_First_With_Its_Own_Subcommand
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      R   : Scripted_Runner;
   begin
      R.Have     := "yyyy";
      R.Compiles := "yyyy";
      Build_Ok (R, Source_Tree (Dir), Library_In (Dir, "x"));
      declare
         Log : constant String := To_String (R.Log);
      begin
         Assert
           (Contains (Log, "zig version"),
            "found by `version`, which is not `--version`");
         Assert
           (Contains (Log, "zig cc -shared -fPIC -O2 -I"),
            "the subcommand comes before the flags");
         Assert
           (not Contains (Log, "--version"),
            "nothing else is asked once it works");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Zig_Cc_Is_Tried_First_With_Its_Own_Subcommand;

   procedure A_Zig_Cc_That_Fails_Is_Named_And_The_Next_Compiler_Is_Tried
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      R      : Scripted_Runner;
      Result : Build_Result;
   begin
      R.Have     := "yyyy";
      R.Compiles := "nyyy";
      Build_Ok (R, Source_Tree (Dir), Library_In (Dir, "x"));
      Assert
        (Contains (To_String (R.Log), "cc --version"),
         "the next one is tried");
      R.Compiles := "nnnn";
      Result     := Build (R, Source_Tree (Dir), Library_In (Dir, "y"));
      Assert (Fails_With (Result, Compile_Failed), "all four failed");
      Assert
        (Contains (Detail (Result), "zig cc: cannot compile with zig"),
         "named as the driver it is");
      Assert
        (Contains (Detail (Result), "  clang: cannot compile with clang"),
         "and the others after it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Zig_Cc_That_Fails_Is_Named_And_The_Next_Compiler_Is_Tried;

   procedure A_Zig_That_Is_Not_There_Is_Probed_And_Never_Run
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      R   : Scripted_Runner;
   begin
      R.Have     := "nyyy";
      R.Compiles := "yyyy";
      Build_Ok (R, Source_Tree (Dir), Library_In (Dir, "x"));
      Assert (Contains (To_String (R.Log), "zig version"), "asked");
      Assert (not Contains (To_String (R.Log), "zig cc"), "not run");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Zig_That_Is_Not_There_Is_Probed_And_Never_Run;

   procedure No_Compiler_Is_A_Distinct_Failure (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      R   : Scripted_Runner;
   begin
      Assert
        (Fails_With
           (Build (R, Source_Tree (Dir), Library_In (Dir, "x")), No_Compiler),
         "none reports a version");
      R.Cannot_Run := True;
      Assert
        (Fails_With
           (Build (R, Source_Tree (Dir), Library_In (Dir, "x")), No_Compiler),
         "none can even be started");
      Assert
        (not Ada.Directories.Exists (Library_In (Dir, "x") & ".lock"),
         "the lock is released");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end No_Compiler_Is_A_Distinct_Failure;

   ---------------------------------------------------------------------------
   --  The compile lock
   ---------------------------------------------------------------------------

   procedure A_Fresh_Compile_Lock_Refuses_And_A_Stale_One_Is_Taken_Over
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir      : constant Scratch := Make;
      Out_Path : constant String  := Library_In (Dir, "locked");
   begin
      Copy_Grammar (Path (Dir, "g"));
      Ada.Directories.Create_Path (Out_Path & ".lock");
      Assert
        (Fails_With
           (Build (Real_Runner, Path (Dir, "g"), Out_Path, Max_Tries => 2),
            Compile_Failed),
         "a fresh lock is honoured");
      Assert
        (Ada.Directories.Exists (Out_Path & ".lock"),
         "the waiter that gave up did not delete it");
      Assert (not Ada.Directories.Exists (Out_Path), "and built nothing");

      Set_Modified (Out_Path & ".lock", Lock_Stale_After + 60.0);
      Build_Ok (Real_Runner, Path (Dir, "g"), Out_Path, Max_Tries => 2);
      Assert (Ada.Directories.Exists (Out_Path), "a stale lock is taken over");
      Assert (not Ada.Directories.Exists (Out_Path & ".lock"), "and released");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Fresh_Compile_Lock_Refuses_And_A_Stale_One_Is_Taken_Over;

   ---------------------------------------------------------------------------
   --  Cloning
   ---------------------------------------------------------------------------

   --  A repository to clone from, so the lock, staging and failure paths run
   --  without leaving the machine.
   procedure Make_Source_Repo (Dir : Scratch) is
   begin
      Ada.Directories.Create_Path (Path (Dir, "tree-sitter-fake"));
      Init_Repo (Path (Dir, "tree-sitter-fake"));
      File_Bytes.Write (Path (Dir, "tree-sitter-fake/README"), "x");
      Git (Path (Dir, "tree-sitter-fake"), "add", "-A");
      Git (Path (Dir, "tree-sitter-fake"), "commit", "-q", "-m", "x");
   end Make_Source_Repo;

   procedure Cloning_Is_Idempotent_And_Leaves_No_Lock_Or_Staging_Behind
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      Source : constant String  := Path (Dir, "tree-sitter-fake");
      Parent : constant String  := Path (Dir, "repos");
   begin
      Make_Source_Repo (Dir);
      declare
         First : constant String := Cloned (Real_Runner, Source, Parent, 5);
      begin
         Assert (Ada.Directories.Exists (First & "/README"), "cloned");
         Assert
           (not Ada.Directories.Exists (First & ".lock"), "lock released");
         Assert
           (Cloned (Real_Runner, Source, Parent, 5) = First,
            "a second call is a no-op");
      end;
      declare
         Search : Ada.Directories.Search_Type;
         Item   : Ada.Directories.Directory_Entry_Type;
      begin
         Ada.Directories.Start_Search (Search, Parent, "*");
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Item);
            Assert
              (not Contains (Ada.Directories.Simple_Name (Item), ".partial"),
               "no staging directory left");
         end loop;
         Ada.Directories.End_Search (Search);
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Cloning_Is_Idempotent_And_Leaves_No_Lock_Or_Staging_Behind;

   procedure A_Stale_Clone_Lock_Is_Taken_Over_And_A_Fresh_One_Is_Not
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      Source : constant String  := Path (Dir, "tree-sitter-fake");
      Parent : constant String  := Path (Dir, "repos");
      Lock   : constant String  := Parent & "/tree-sitter-fake.lock";
   begin
      Make_Source_Repo (Dir);
      Ada.Directories.Create_Path (Lock);
      Assert
        (Clone_Fails_With
           (Ensure_Cloned (Real_Runner, Source, Parent, 2), Clone_Failed),
         "a fresh lock with nothing cloned");
      Assert (Ada.Directories.Exists (Lock), "left alone");

      Set_Modified (Lock, Lock_Stale_After + 60.0);
      Assert
        (Ada.Directories.Exists
           (Cloned (Real_Runner, Source, Parent, 2) & "/README"),
         "a real clone and not an empty directory");
      Assert (not Ada.Directories.Exists (Lock), "the lock is released");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Stale_Clone_Lock_Is_Taken_Over_And_A_Fresh_One_Is_Not;

   procedure A_Fresh_Lock_Is_Waited_Out_When_The_Holder_Finishes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      Parent : constant String  := Path (Dir, "repos");
   begin
      Ada.Directories.Create_Path (Parent & "/tree-sitter-fake");
      Ada.Directories.Create_Path (Parent & "/tree-sitter-fake.lock");
      Assert
        (Cloned (Real_Runner, "ignored/tree-sitter-fake", Parent, 3) =
         Parent & "/tree-sitter-fake",
         "the directory is already there");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Fresh_Lock_Is_Waited_Out_When_The_Holder_Finishes;

   procedure A_Clone_That_Fails_Is_Reported_And_Leaves_No_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      Parent : constant String  := Path (Dir, "repos");
   begin
      Assert
        (Clone_Fails_With
           (Ensure_Cloned
              (Real_Runner, Path (Dir, "tree-sitter-absent"), Parent, 5),
            Clone_Failed),
         "reported");
      Assert
        (not Ada.Directories.Exists (Parent & "/tree-sitter-absent"),
         "no half-built directory");
      Assert
        (not Ada.Directories.Exists (Parent & "/tree-sitter-absent.lock"),
         "no lock left");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Clone_That_Fails_Is_Reported_And_Leaves_No_Directory;

   procedure A_Git_That_Cannot_Be_Started_Is_A_Clone_Failure
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      R   : Scripted_Runner;
   begin
      R.Cannot_Run := True;
      Assert
        (Clone_Fails_With
           (Ensure_Cloned (R, "https://host/tree-sitter-x", Path (Dir, "r")),
            Clone_Failed),
         "a failure to start git, not an escaping exception");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Git_That_Cannot_Be_Started_Is_A_Clone_Failure;

   --  Creates a directory or a file a moment after it is started: the other
   --  process finishing while this one waits.
   task type Creator is
      entry Start (Target : String; Is_Directory : Boolean);
   end Creator;

   task body Creator is
      Where : Unbounded_String;
      Dir   : Boolean;
   begin
      accept Start (Target : String; Is_Directory : Boolean) do
         Where := To_Unbounded_String (Target);
         Dir   := Is_Directory;
      end Start;
      delay 0.5;
      if Dir then
         Ada.Directories.Create_Path (To_String (Where));
      else
         File_Bytes.Write (To_String (Where), "built" & LF);
      end if;
   end Creator;

   procedure A_Waiter_Returns_As_Soon_As_The_Clone_Appears
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch           := Make;
      Parent  : constant String            := Path (Dir, "repos");
      Maker   : Creator;
      Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
   begin
      Ada.Directories.Create_Path (Parent & "/tree-sitter-fake.lock");
      Maker.Start (Parent & "/tree-sitter-fake", True);
      Assert
        (Cloned (Real_Runner, "x/tree-sitter-fake", Parent, 100) =
         Parent & "/tree-sitter-fake",
         "the clone another process made");
      Assert
        (Ada.Calendar.Clock - Started < 5.0,
         "returned when it appeared and not after the full wait");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Waiter_Returns_As_Soon_As_The_Clone_Appears;

   procedure A_Waiter_Returns_As_Soon_As_The_Library_Is_Built
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir      : constant Scratch           := Make;
      Out_Path : constant String            := Library_In (Dir, "waited");
      Maker    : Creator;
      Started  : constant Ada.Calendar.Time := Ada.Calendar.Clock;
   begin
      Copy_Grammar (Path (Dir, "g"));
      Ada.Directories.Create_Path (Out_Path & ".lock");
      delay 1.1;
      Maker.Start (Out_Path, False);
      Build_Ok (Real_Runner, Path (Dir, "g"), Out_Path, Max_Tries => 100);
      Assert (Ada.Directories.Exists (Out_Path), "built by the other process");
      Assert
        (Ada.Calendar.Clock - Started < 6.0,
         "returned when it was built and not after the full wait");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Waiter_Returns_As_Soon_As_The_Library_Is_Built;

   procedure A_Grammar_That_Cannot_Be_Built_Is_Not_Prepared_With_Its_Reason
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch  := Make;
      Got : constant Resolved :=
        Resolve_And_Load
          (Real_Runner, Loader, Path (Dir), Path (Dir, "cache"),
           "tree-sitter-nothing", No_Text, No_Text);
   begin
      Assert
        (Got.Kind = Not_Prepared and then Got.Why.Kind = Parser_Source_Missing,
         "no parser to build");
      Assert
        (Contains (Describe (Got.Why), "PARSER_SOURCE_MISSING: "),
         "described by its kind and its detail");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Grammar_That_Cannot_Be_Built_Is_Not_Prepared_With_Its_Reason;

   procedure A_Long_Report_Is_Kept_Whole (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      R      : Scripted_Runner;
      Result : Build_Result;
   begin
      R.Have     := "nnnn";
      R.Have (4) := 'y';
      R.Verbose  := True;
      Result     := Build (R, Source_Tree (Dir), Library_In (Dir, "x"));
      Assert (Fails_With (Result, Compile_Failed), "failed");
      Assert
        (Detail (Result)'Length > 400
         and then Contains (Detail (Result), "eeeeeeee" & LF),
         "more than an exception message holds, and the end of it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Long_Report_Is_Kept_Whole;

   procedure A_Library_Is_Kept_Under_Its_Symbol_With_The_Systems_Extension
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Library_Path (Loader, "/g", "tree_sitter_x") =
         "/g/lib/tree_sitter_x." & Loader.Extension,
         "the path");
   end A_Library_Is_Kept_Under_Its_Symbol_With_The_Systems_Extension;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Tree_Sitter.Preparation");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Grammar_Compiles_Into_A_Directory_That_Does_Not_Exist_Yet'Access,
         "A grammar compiles into a directory that does not exist yet");
      Register_Routine
        (T, A_Compiled_Grammar_Loads_And_An_Unknown_Symbol_Does_Not'Access,
         "A compiled grammar loads and an unknown symbol does not");
      Register_Routine
        (T, A_Grammar_In_A_Subdirectory_Loads_By_Its_Explicit_Symbol'Access,
         "A grammar in a subdirectory loads by its explicit symbol");
      Register_Routine
        (T, Building_Again_Does_Nothing_Until_A_Source_Is_Newer'Access,
         "Building again does nothing until a source is newer");
      Register_Routine
        (T, A_Tree_With_No_Parser_Is_Refused_Not_Compiled_Into_Nothing'Access,
         "A tree with no parser is refused, not compiled into nothing");
      Register_Routine
        (T, A_Scanner_In_Another_Language_Is_Refused'Access,
         "A scanner in another language is refused");
      Register_Routine
        (T,
         Source_That_Does_Not_Compile_Names_Every_Compiler_That_Failed'Access,
         "Source that does not compile is refused and releases its lock");
      Register_Routine
        (T, Every_Compiler_Found_Gets_An_Attempt_In_Order'Access,
         "Every compiler found gets an attempt, in order");
      Register_Routine
        (T,
         A_Compiler_That_Reports_A_Version_But_Cannot_Compile_Is_Skipped'
           Access,
         "A compiler that reports a version but cannot compile is skipped");
      Register_Routine
        (T, Zig_Cc_Is_Tried_First_With_Its_Own_Subcommand'Access,
         "Zig cc is tried first, with its own subcommand");
      Register_Routine
        (T, A_Zig_Cc_That_Fails_Is_Named_And_The_Next_Compiler_Is_Tried'Access,
         "A zig cc that fails is named and the next compiler is tried");
      Register_Routine
        (T, A_Zig_That_Is_Not_There_Is_Probed_And_Never_Run'Access,
         "A zig that is not there is probed and never run");
      Register_Routine
        (T, No_Compiler_Is_A_Distinct_Failure'Access,
         "No compiler is a distinct failure");
      Register_Routine
        (T, A_Fresh_Compile_Lock_Refuses_And_A_Stale_One_Is_Taken_Over'Access,
         "A fresh compile lock refuses and a stale one is taken over");
      Register_Routine
        (T, Cloning_Is_Idempotent_And_Leaves_No_Lock_Or_Staging_Behind'Access,
         "Cloning is idempotent and leaves no lock or staging behind");
      Register_Routine
        (T, A_Stale_Clone_Lock_Is_Taken_Over_And_A_Fresh_One_Is_Not'Access,
         "A stale clone lock is taken over and a fresh one is not");
      Register_Routine
        (T, A_Fresh_Lock_Is_Waited_Out_When_The_Holder_Finishes'Access,
         "A lock is ignored when the clone is already there");
      Register_Routine
        (T, A_Clone_That_Fails_Is_Reported_And_Leaves_No_Directory'Access,
         "A clone that fails is reported and leaves no directory");
      Register_Routine
        (T, A_Git_That_Cannot_Be_Started_Is_A_Clone_Failure'Access,
         "A git that cannot be started is a clone failure");
      Register_Routine
        (T, A_Waiter_Returns_As_Soon_As_The_Clone_Appears'Access,
         "A waiter returns as soon as the clone appears");
      Register_Routine
        (T, A_Waiter_Returns_As_Soon_As_The_Library_Is_Built'Access,
         "A waiter returns as soon as the library is built");
      Register_Routine
        (T,
         A_Grammar_That_Cannot_Be_Built_Is_Not_Prepared_With_Its_Reason'Access,
         "A grammar that cannot be built is not prepared, with its reason");
      Register_Routine
        (T, A_Long_Report_Is_Kept_Whole'Access, "A long report is kept whole");
      Register_Routine
        (T,
         A_Library_Is_Kept_Under_Its_Symbol_With_The_Systems_Extension'Access,
         "A library is kept under its symbol with the system's extension");
   end Register_Tests;

end Synapse.Adapters.Tree_Sitter.Preparation.Tests;
