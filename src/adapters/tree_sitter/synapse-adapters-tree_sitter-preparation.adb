with Ada.Calendar;
with Ada.Directories;

with Synapse.Adapters.Dir_Lock;
with Synapse.Core.Text_Lists;
with Synapse.Core.Decimal_Image;

package body Synapse.Adapters.Tree_Sitter.Preparation is

   use Ada.Strings.Unbounded;
   use Build_Results;
   use type Ada.Calendar.Time;
   use type Ada.Directories.File_Kind;

   LF : constant Character := Character'Val (10);

   --  Compilers in the order they are tried. The first is a driver and not a
   --  compiler of its own: `zig cc`.
   Compiler_Count : constant := 4;

   function Compiler_Name (Index : Positive) return String is
     (case Index is when 1 => "zig", when 2 => "cc", when 3 => "gcc",
        when others => "clang");

   --  What follows the program name before the compile flags, if anything.
   function Compiler_Subcommand (Index : Positive) return String is
     (if Index = 1 then "cc" else "");

   function Version_Argument (Index : Positive) return String is
     (if Index = 1 then "version" else "--version");

   --  What a message calls the compiler: `zig cc`, or just `clang`.
   function Compiler_Label (Index : Positive) return String is
     (if Compiler_Subcommand (Index) = "" then Compiler_Name (Index)
      else Compiler_Name (Index) & " " & Compiler_Subcommand (Index));

   function Exists (Path : String) return Boolean is
     (Ada.Directories.Exists (Path));

   function Ok (Result : Runner.Result) return Boolean is
     (Runner.Succeeded (Result));

   function Run_Quietly
     (Run  : in out Runner.Runner'Class; Program : String;
      Args :        Core.Text_Lists.Vector) return Runner.Result
   is
   begin
      return Run.Run (Program, Args, (others => <>));
   end Run_Quietly;

   procedure Add (Args : in out Core.Text_Lists.Vector; Arg : String) is
   begin
      Args.Append (To_Unbounded_String (Arg));
   end Add;

   function Args_Of (A1 : String) return Core.Text_Lists.Vector is
      Result : Core.Text_Lists.Vector;
   begin
      Result.Append (To_Unbounded_String (A1));
      return Result;
   end Args_Of;

   --  Whether the program exists and exits 0: not proof it can compile (a
   --  compiler can report its version while missing its backend). It decides
   --  which are tried and never which one wins.
   function Probe
     (Run : in out Runner.Runner'Class; Index : Positive) return Boolean
   is
   begin
      return
        Ok
          (Run_Quietly
             (Run, Compiler_Name (Index), Args_Of (Version_Argument (Index))));
   exception
      when Runner.Process_Failure =>
         return False;
   end Probe;

   --  Newer than every source and not only the parser: an external scanner
   --  changes on its own, and checking the parser alone would reuse a stale
   --  one.
   function Up_To_Date
     (Out_Path : String; Sources : Core.Text_Lists.Vector) return Boolean
   is
   begin
      if not Exists (Out_Path) then
         return False;
      end if;
      declare
         Built : constant Ada.Calendar.Time :=
           Ada.Directories.Modification_Time (Out_Path);
      begin
         for Source of Sources loop
            if not Exists (To_String (Source))
              or else Built <
                Ada.Directories.Modification_Time (To_String (Source))
            then
               return False;
            end if;
         end loop;
      end;
      return True;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         return False;
   end Up_To_Date;

   function Parent_Of (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (Path'First .. I - 1);
         end if;
      end loop;
      return "";
   end Parent_Of;

   function Minutes (D : Duration) return String is
   begin
      return Core.Decimal_Image.Image (Natural (D / 60.0));
   end Minutes;

   procedure Delete_Quietly (Path : String) is
   begin
      if Exists (Path) then
         if Ada.Directories.Kind (Path) = Ada.Directories.Directory then
            Ada.Directories.Delete_Tree (Path);
         else
            Ada.Directories.Delete_File (Path);
         end if;
      end if;
   exception
      when others =>
         null;
   end Delete_Quietly;

   function Trim_Trailing_LF (Text : String) return String is
      Last : Natural := Text'Last;
   begin
      while Last >= Text'First and then Text (Last) = LF loop
         Last := Last - 1;
      end loop;
      return Text (Text'First .. Last);
   end Trim_Trailing_LF;

   function Failed (Kind : Failure_Kind; Detail : String) return Failure is
     (Kind => Kind, Detail => To_Unbounded_String (Detail));

   function Describe (F : Failure) return String is
     (Failure_Kind'Image (F.Kind) & ": " & To_String (F.Detail));

   Done : constant Build_Result := Build_Results.Success (Core.Unit.Nothing);

   function Build_Failed
     (Kind : Failure_Kind; Detail : String) return Build_Result is
     (Build_Results.Failure (Failed (Kind, Detail)));

   function Clone_Failure
     (Kind : Failure_Kind; Detail : String) return Clone_Result is
     (Clone_Results.Failure (Failed (Kind, Detail)));

   ---------------------------------------------------------------------------
   --  Building
   ---------------------------------------------------------------------------

   function Compile
     (Run : in out Runner.Runner'Class; Repo_Dir : String; Src_Dir : String;
      Out_Path : String; Sources : Core.Text_Lists.Vector) return Build_Result
   is
      Args   : Core.Text_Lists.Vector;
      Tried  : Natural := 0;
      Report : Unbounded_String;
   begin
      Add (Args, "-shared");
      Add (Args, "-fPIC");
      Add (Args, "-O2");
      Add (Args, "-I" & Src_Dir);
      Add (Args, "-o");
      Add (Args, Out_Path);
      for Source of Sources loop
         Args.Append (Source);
      end loop;
      for Index in 1 .. Compiler_Count loop
         if Probe (Run, Index) then
            Tried := Tried + 1;
            declare
               Full    : Core.Text_Lists.Vector;
               Result  : Runner.Result;
               Started : Boolean := True;
            begin
               if Compiler_Subcommand (Index) /= "" then
                  Add (Full, Compiler_Subcommand (Index));
               end if;
               for Arg of Args loop
                  Full.Append (Arg);
               end loop;
               begin
                  Result := Run_Quietly (Run, Compiler_Name (Index), Full);
               exception
                  when Runner.Process_Failure =>
                     Started := False;
               end;
               if not Started then
                  Append
                    (Report,
                     "  " & Compiler_Label (Index) & ": not started" & LF);
               elsif Ok (Result) then
                  return Done;
               else
                  Append
                    (Report,
                     "  " & Compiler_Label (Index) & ": " &
                     Trim_Trailing_LF (To_String (Result.Errors)) & LF);
               end if;
            end;
         end if;
      end loop;
      if Tried = 0 then
         return
           Build_Failed
             (No_Compiler,
              "no C compiler found (tried zig cc, cc, gcc, clang)");
      end if;
      return
        Build_Failed
          (Compile_Failed,
           "compiling " & Repo_Dir & " failed with every compiler found:" &
           LF & To_String (Report));
   end Compile;

   function Build
     (Run : in out Runner.Runner'Class; Repo_Dir : String; Out_Path : String;
      Max_Tries :        Positive := Default_Lock_Tries) return Build_Result
   is
      Src_Dir   : constant String := Repo_Dir & "/src";
      Parser_C  : constant String := Src_Dir & "/parser.c";
      Scanner_C : constant String := Src_Dir & "/scanner.c";
      Scanner_X : constant String := Src_Dir & "/scanner.cc";
      Sources   : Core.Text_Lists.Vector;
      Lock_Dir  : constant String := Out_Path & ".lock";
      Lock      : Dir_Lock.Lock;
   begin
      if not Exists (Parser_C) then
         return
           Build_Failed (Parser_Source_Missing, Parser_C & " does not exist");
      end if;
      Sources.Append (To_Unbounded_String (Parser_C));
      if Exists (Scanner_C) then
         Sources.Append (To_Unbounded_String (Scanner_C));
      elsif Exists (Scanner_X) then
         return
           Build_Failed
             (Compile_Failed,
              Repo_Dir & " has a C++ scanner, which is not supported");
      end if;

      if Up_To_Date (Out_Path, Sources) then
         return Done;
      end if;

      --  The directory the lock is made in must exist: a fresh grammars
      --  directory has none on its first compile.
      if Parent_Of (Out_Path) /= "" then
         Ada.Directories.Create_Path (Parent_Of (Out_Path));
      end if;

      --  Re-checked every wait: another process may finish while this one
      --  waits, which ends the wait without contending for a lock this call no
      --  longer needs.
      for Attempt in 1 .. Max_Tries loop
         Dir_Lock.Try_Acquire (Lock_Dir, Lock_Stale_After, Lock);
         exit when Dir_Lock.Held (Lock);
         if Up_To_Date (Out_Path, Sources) then
            return Done;
         end if;
         if Attempt < Max_Tries then
            delay 0.2;
         end if;
      end loop;
      if not Dir_Lock.Held (Lock) then
         return
           Build_Failed
             (Compile_Failed,
              "timed out waiting for the compile lock " & Lock_Dir &
              ": another process is compiling this grammar, or one was " &
              "killed within the last " & Minutes (Lock_Stale_After) &
              " minutes");
      end if;

      if Up_To_Date (Out_Path, Sources) then
         return Done;
      end if;

      return Compile (Run, Repo_Dir, Src_Dir, Out_Path, Sources);
   end Build;

   ---------------------------------------------------------------------------
   --  Cloning
   ---------------------------------------------------------------------------

   function Stamp return String is
      Epoch : constant Ada.Calendar.Time := Ada.Calendar.Time_Of (1_970, 1, 1);
      Micros : constant Long_Long_Integer :=
        Long_Long_Integer (Ada.Calendar.Clock - Epoch) * 1_000_000;
   begin
      return Core.Decimal_Image.Image (Micros);
   end Stamp;

   --  Clones into a private staging directory and publishes with one atomic
   --  rename. Losing the rename is the ordinary way two concurrent clones end:
   --  the winner's copy is as good as this one.
   function Clone_Into
     (Run : in out Runner.Runner'Class; Repo_Url : String; Repo_Dir : String)
      return Clone_Result
   is
      Staged  : constant String := Repo_Dir & ".partial." & Stamp;
      Args    : Core.Text_Lists.Vector;
      Result  : Runner.Result;
      Started : Boolean         := True;
   begin
      Add (Args, "clone");
      Add (Args, "--depth");
      Add (Args, "1");
      Add (Args, "-q");
      Add (Args, Repo_Url);
      Add (Args, Staged);
      begin
         Result := Run_Quietly (Run, "git", Args);
      exception
         when Runner.Process_Failure =>
            Started := False;
      end;
      if not Started then
         Delete_Quietly (Staged);
         return Clone_Failure (Clone_Failed, "git could not be started");
      end if;
      if not Ok (Result) then
         Delete_Quietly (Staged);
         return
           Clone_Failure
             (Clone_Failed,
              "git clone of " & Repo_Url & " failed: " &
              Trim_Trailing_LF (To_String (Result.Errors)));
      end if;
      begin
         Ada.Directories.Rename (Staged, Repo_Dir);
      exception
         when others =>
            Delete_Quietly (Staged);
            if not Exists (Repo_Dir) then
               return
                 Clone_Failure
                   (Clone_Failed,
                    "could not publish the clone of " & Repo_Url);
            end if;
      end;
      return Clone_Results.Success (To_Unbounded_String (Repo_Dir));
   end Clone_Into;

   function Ensure_Cloned
     (Run          : in out Runner.Runner'Class; Repo_Url : String;
      Repos_Parent :        String; Max_Tries : Positive := Default_Lock_Tries)
      return Clone_Result
   is
      Name : constant String := Core.Grammar_Registry.Repo_Name_Of (Repo_Url);
      Repo_Dir : constant String       := Repos_Parent & "/" & Name;
      Lock_Dir : constant String       := Repo_Dir & ".lock";
      Lock     : Dir_Lock.Lock;
      Present  : constant Clone_Result :=
        Clone_Results.Success (To_Unbounded_String (Repo_Dir));
   begin
      if Exists (Repo_Dir) then
         return Present;
      end if;
      Ada.Directories.Create_Path (Repos_Parent);

      for Attempt in 1 .. Max_Tries loop
         Dir_Lock.Try_Acquire (Lock_Dir, Lock_Stale_After, Lock);
         exit when Dir_Lock.Held (Lock);
         exit when Exists (Repo_Dir);  --  the holder may have finished
         if Attempt < Max_Tries then
            delay 0.2;
         end if;
      end loop;

      if Dir_Lock.Held (Lock) then
         if not Exists (Repo_Dir) then  --  re-checked under the lock
            return Clone_Into (Run, Repo_Url, Repo_Dir);
         end if;
         return Present;
      end if;

      --  Not old enough to take over and still nothing there: a live clone
      --  slower than the wait, or a crash too recent. The path is named
      --  because a clone failure alone reads as a network error.
      if not Exists (Repo_Dir) then
         return
           Clone_Failure
             (Clone_Failed,
              "timed out waiting for the grammar lock " & Lock_Dir &
              ": another process is cloning, or one was killed within the " &
              "last " & Minutes (Lock_Stale_After) & " minutes");
      end if;
      return Present;
   end Ensure_Cloned;

   ---------------------------------------------------------------------------
   --  Loading
   ---------------------------------------------------------------------------

   function Library_Path
     (Loader       : Synapse.Ports.Library_Loader.Loader'Class;
      Grammars_Dir : String; Symbol : String) return String is
     (Grammars_Dir & "/lib/" & Symbol & "." & Loader.Extension);

   function Resolve_And_Load
     (Run        : in out Runner.Runner'Class;
      Loader     : in out Synapse.Ports.Library_Loader.Loader'Class;
      Repo_Dir   :        String; Grammars_Dir : String; Name : String;
      Sub_Path   :        Core.Grammar_Registry.Maybe_Text;
      Sub_Symbol :        Core.Grammar_Registry.Maybe_Text;
      Max_Tries  :        Positive := Default_Lock_Tries) return Resolved
   is
      Symbol   : constant String       :=
        (if Sub_Symbol.Found then To_String (Sub_Symbol.Value)
         else Core.Grammar_Registry.Symbol_For (Name));
      Lib_Path : constant String       :=
        Library_Path (Loader, Grammars_Dir, Symbol);
      Src_Root : constant String       :=
        (if Sub_Path.Found then Repo_Dir & "/" & To_String (Sub_Path.Value)
         else Repo_Dir);
      Built    : constant Build_Result :=
        Build (Run, Src_Root, Lib_Path, Max_Tries);
   begin
      if not Is_Success (Built) then
         return (Kind => Not_Prepared, Why => Error (Built));
      end if;
      declare
         Loaded_Language : constant Grammar.Load_Result :=
           Grammar.Load_Language (Loader, Lib_Path, Symbol);
      begin
         if not Grammar.Load_Results.Is_Success (Loaded_Language) then
            return
              (Kind  => Not_Loadable,
               Error => Grammar.Load_Results.Error (Loaded_Language));
         end if;
         return
           (Kind => Loaded,
            Item => Grammar.Load_Results.Value (Loaded_Language));
      end;
   end Resolve_And_Load;

end Synapse.Adapters.Tree_Sitter.Preparation;
