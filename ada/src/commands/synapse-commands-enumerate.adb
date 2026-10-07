with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.Git_Identity;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Enumerate;
with Synapse.Core.Identity;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Variables;

package body Synapse.Commands.Enumerate is

   use Ada.Strings.Unbounded;
   use type Synapse.Commands.Graph_Support.Grep_Outcome;
   use type Ada.Directories.File_Kind;

   package Support renames Synapse.Commands.Graph_Support;
   package Runner_Port renames Synapse.Ports.Process_Runner;

   Prog : constant String    := "synapse-enumerate";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse enumerate [--reenumerate]" & LF;

   --  The size a file may have and still be graphed, with the skips reported.
   Default_Max_File_Bytes : constant := 1_048_576;

   function Variable (Env : Environment; Name : String) return String is
      Got : constant Ports.Variables.Maybe_Value := Env.Vars.Get (Name);
   begin
      return (if Got.Found then To_String (Got.Value) else "");
   end Variable;

   function Max_File_Bytes (Env : Environment) return Long_Long_Integer is
      Raw   : constant String   := Variable (Env, "SYNAPSE_MAX_FILE_BYTES");
      First : constant Positive :=
        Raw'First +
        (if Raw'Length > 0 and then Raw (Raw'First) = '+' then 1 else 0);
   begin
      if Raw'Length = 0 or else First > Raw'Last
        or else not (for all C of Raw (First .. Raw'Last) => C in '0' .. '9')
      then
         return Default_Max_File_Bytes;
      end if;
      return Long_Long_Integer'Value (Raw (First .. Raw'Last));
   exception
      when Constraint_Error =>
         return Default_Max_File_Bytes;
   end Max_File_Bytes;

   --  The listing without the lines the user's own patterns exclude:
   --  `SYNAPSE_EXTRA_EXCLUDE_RE` and each pattern line of the ignore
   --  configuration, as one `grep -vE`. The listing as it is when there are
   --  none, since an empty pattern matches every line.
   function Without_User_Patterns
     (Env : Environment; Listing : String; Failed : out Boolean) return String
   is
      Pattern : Unbounded_String :=
        To_Unbounded_String (Variable (Env, "SYNAPSE_EXTRA_EXCLUDE_RE"));
   begin
      Failed := False;
      if Env.Vars.Get ("HOME").Found then
         declare
            Found : constant Adapters.Conf_Files.Maybe_Path :=
              Adapters.Conf_Files.Resolve_Conf_Path
                (Env.Vars.all, "synapse-ignore-files.conf");
            Path  : constant String                         :=
              (if Found.Found then To_String (Found.Value)
               else Variable (Env, "HOME") &
                 "/.claude/synapse-ignore-files.conf");
            Text  : Unbounded_String;
            Read  : Boolean;
         begin
            Support.Read_File (Path, 1_048_576, Text, Read);
            if Read then
               declare
                  Whole : constant String := To_String (Text);
                  Start : Positive        := Whole'First;
               begin
                  for I in Whole'First .. Whole'Last + 1 loop
                     if I > Whole'Last or else Whole (I) = LF then
                        declare
                           Raw : constant String := Whole (Start .. I - 1);
                           Cut : Natural         := Raw'Last;
                        begin
                           for K in Raw'Range loop
                              if Raw (K) = '#' then
                                 Cut := K - 1;
                                 exit;
                              end if;
                           end loop;
                           declare
                              First : Positive := Raw'First;
                              Last  : Natural  := Cut;
                           begin
                              while First <= Last
                                and then Raw (First) in
                                  ' ' | ASCII.HT | ASCII.CR
                              loop
                                 First := First + 1;
                              end loop;
                              while Last >= First
                                and then Raw (Last) in
                                  ' ' | ASCII.HT | ASCII.CR
                              loop
                                 Last := Last - 1;
                              end loop;
                              if Last >= First then
                                 if Length (Pattern) > 0 then
                                    Append (Pattern, "|");
                                 end if;
                                 Append (Pattern, Raw (First .. Last));
                              end if;
                           end;
                        end;
                        Start := I + 1;
                     end if;
                  end loop;
               end;
            end if;
         end;
      end if;

      if Length (Pattern) = 0 then
         return Listing;
      end if;
      declare
         Kept    : Unbounded_String;
         Outcome : Support.Grep_Outcome;
      begin
         Support.Grep
           (Env, "-vE", To_String (Pattern), Listing, Kept, Outcome);
         --  Nothing left is a result, not a failure.
         Failed := Outcome = Support.Failed;
         return To_String (Kept);
      end;
   end Without_User_Patterns;

   procedure Enumerate_Into
     (Env    :     Environment; Repo_Root, All_Path, Oversize_Path : String;
      Reason : out Unbounded_String)
   is
      Args    : Lists.Vector;
      Listed  : Runner_Port.Result;
      All_Out : Unbounded_String;
      Big_Out : Unbounded_String;
      Cap     : constant Long_Long_Integer := Max_File_Bytes (Env);
      Failed  : Boolean;
   begin
      Reason := To_Unbounded_String ("git ls-files failed");
      --  Truncated first, so a rebuild keeps no finding of the last run.
      Support.Write_File (Oversize_Path, "");
      Args.Append (To_Unbounded_String ("ls-files"));
      Listed :=
        Env.Runner.Run
          ("git", Args,
           (Cwd   => To_Unbounded_String (Repo_Root), Has_Stdin => False,
            Stdin => Null_Unbounded_String));
      if Listed.Exit_Code /= 0 then
         return;
      end if;
      declare
         Candidates : constant String :=
           Without_User_Patterns (Env, To_String (Listed.Output), Failed);
         Start      : Positive        := Candidates'First;
      begin
         if Failed then
            Reason := To_Unbounded_String ("grep failed");
            return;
         end if;
         for I in Candidates'First .. Candidates'Last + 1 loop
            if I > Candidates'Last or else Candidates (I) = LF then
               declare
                  Path : constant String := Candidates (Start .. I - 1);
               begin
                  Start := I + 1;
                  if Path'Length > 0
                    and then not Core.Enumerate.Is_Excluded (Path)
                  then
                     declare
                        Full : constant String := Repo_Root & "/" & Path;
                     begin
                        if Ada.Directories.Kind (Full) =
                          Ada.Directories.Ordinary_File
                        then
                           declare
                              Size : constant Long_Long_Integer :=
                                Long_Long_Integer
                                  (Ada.Directories.Size (Full));
                           begin
                              if Size > Cap then
                                 Append
                                   (Big_Out,
                                    Core.Decimal_Image.Image (Size) & HT &
                                    Path & LF);
                              else
                                 Append (All_Out, Path & LF);
                              end if;
                           end;
                        end if;
                     exception
                        --  A file that is gone or cannot be measured is not
                        --  one to graph.
                        when others =>
                           null;
                     end;
                  end if;
               end;
            end if;
         end loop;
      end;
      Support.Write_File (All_Path, To_String (All_Out));
      Support.Write_File (Oversize_Path, To_String (Big_Out));
      Reason := Null_Unbounded_String;
   end Enumerate_Into;

   type Row is record
      Size : Long_Long_Integer;
      Path : Unbounded_String;
   end record;

   package Row_Vectors is new Ada.Containers.Vectors (Positive, Row);

   function Larger (A, B : Row) return Boolean is (A.Size > B.Size);

   package Row_Sorting is new Row_Vectors.Generic_Sorting ("<" => Larger);

   --  `skipped N file(s) over CAP bytes (largest first):` and the five
   --  biggest.
   procedure Report_Oversize (Env : Environment; Oversize_Path : String) is
      Text : Unbounded_String;
      Read : Boolean;
      Rows : Row_Vectors.Vector;
   begin
      Support.Read_File (Oversize_Path, 64 * 1_024 * 1_024, Text, Read);
      if not Read or else Length (Text) = 0 then
         return;
      end if;
      declare
         Whole : constant String := To_String (Text);
         Start : Positive        := Whole'First;
      begin
         for I in Whole'First .. Whole'Last + 1 loop
            if I > Whole'Last or else Whole (I) = LF then
               declare
                  Line : constant String := Whole (Start .. I - 1);
                  Tab  : Natural         := 0;
               begin
                  Start := I + 1;
                  for K in Line'Range loop
                     if Line (K) = HT then
                        Tab := K;
                        exit;
                     end if;
                  end loop;
                  if Tab > Line'First
                    and then
                    (for all C of Line (Line'First .. Tab - 1) =>
                       C in '0' .. '9')
                  then
                     Rows.Append
                       (Row'
                          (Size =>
                             Long_Long_Integer'Value
                               (Line (Line'First .. Tab - 1)),
                           Path =>
                             To_Unbounded_String
                               (Line (Tab + 1 .. Line'Last))));
                  end if;
               exception
                  when Constraint_Error =>
                     null;
               end;
            end if;
         end loop;
      end;
      if Rows.Is_Empty then
         return;
      end if;
      Say
        (Env,
         "skipped " & Core.Decimal_Image.Image (Natural (Rows.Length)) &
         " file(s) over " & Core.Decimal_Image.Image (Max_File_Bytes (Env)) &
         " bytes (largest first):" & LF);
      Row_Sorting.Sort (Rows);
      for I in 1 .. Natural'Min (5, Natural (Rows.Length)) loop
         declare
            Size : constant String := Core.Decimal_Image.Image (Rows (I).Size);
         begin
            Say
              (Env,
               "  " & [1 .. Natural'Max (0, 10 - Size'Length) => ' '] & Size &
               "  " & To_String (Rows (I).Path) & LF);
         end;
      end loop;
   end Report_Oversize;

   function Count_Lines (Env : Environment; Path : String) return Natural is
      Text  : Unbounded_String;
      Read  : Boolean;
      Count : Natural := 0;
   begin
      Support.Read_File
        (Path, Support.Max_Listing_Bytes (Env, 256 * 1_024 * 1_024), Text,
         Read);
      if Read then
         for C of To_String (Text) loop
            if C = LF then
               Count := Count + 1;
            end if;
         end loop;
      end if;
      return Count;
   end Count_Lines;

   function Size_Of (Path : String) return Long_Long_Integer is
   begin
      if Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File
      then
         return Long_Long_Integer (Ada.Directories.Size (Path));
      end if;
      return 0;
   exception
      when others =>
         return 0;
   end Size_Of;

   function Ensure
     (Env : Environment; Repo_Root, Work_Dir : String; Reenumerate : Boolean)
      return Boolean
   is
      All_Path      : constant String := Work_Dir & "/all.txt";
      Oversize_Path : constant String := Work_Dir & "/oversize.txt";
      Reason        : Unbounded_String;
   begin
      begin
         Ada.Directories.Create_Path (Work_Dir);
      exception
         when others =>
            null;
      end;
      --  By size and not by existence: a zero-byte file from an interrupted
      --  run is not an enumeration.
      if Size_Of (All_Path) = 0 or else Reenumerate then
         Say (Env, "--- enumerating tracked files" & LF);
         Enumerate_Into (Env, Repo_Root, All_Path, Oversize_Path, Reason);
         if Length (Reason) > 0 then
            Complain (Env, Prog & ": " & To_String (Reason) & LF);
            return False;
         end if;
      end if;
      Report_Oversize (Env, Oversize_Path);
      Say
        (Env,
         "enumerated: " &
         Core.Decimal_Image.Image (Count_Lines (Env, All_Path)) & LF);
      return True;
   end Ensure;

   function Enumerate
     (Env : Environment; Identity_Path : String; Reenumerate : Boolean)
      return Exit_Code
   is
      Resolved : Core.Identity.Resolved;
   begin
      begin
         Resolved := Adapters.Git_Identity.Resolve (Identity_Path);
      exception
         when others =>
            Complain (Env, Prog & ": not inside a git repo" & LF);
            return 1;
      end;
      declare
         Work : constant Support.Maybe_Path := Support.Work_Dir (Env, Prog);
      begin
         if not Work.Found then
            return 1;
         end if;
         return
           (if
              Ensure
                (Env, To_String (Resolved.Where.Repo_Root),
                 To_String (Work.Value), Reenumerate)
            then 0
            else 1);
      end;
   end Enumerate;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Reenumerate : Boolean := False;
   begin
      for Arg_Item of Args loop
         declare
            Arg : constant String := To_String (Arg_Item);
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg = "--reenumerate" then
               Reenumerate := True;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
      end loop;
      return Enumerate (Env, ".", Reenumerate);
   end Run;

end Synapse.Commands.Enumerate;
