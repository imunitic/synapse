with Ada.Directories;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

with Synapse.Adapters.File_Bytes;

package body Synapse.Adapters.System_Process is

   use Ada.Strings.Unbounded;
   use type GNAT.OS_Lib.String_Access;

   --  Runs in the directory in $1 (if any) with standard input from $2,
   --  standard output to $3 and standard error to $4, then becomes the
   --  program. Every value reaches the script as an argument, never as shell
   --  text.
   Script : constant String :=
     "dir=$1; in=$2; out=$3; err=$4; shift 4; "
     & "if [ -n ""$dir"" ]; then cd ""$dir"" || exit 127; fi; "
     & "exec ""$@"" <""$in"" >""$out"" 2>""$err""";

   function Temp_File (Content : String := "") return String
   is (File_Bytes.Temp_File (Content));

   procedure Remove (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Remove;

   function Found (Program : String) return Boolean is
      Resolved : GNAT.OS_Lib.String_Access;
   begin
      for C of Program loop
         if C = '/' then
            return GNAT.OS_Lib.Is_Executable_File (Program);
         end if;
      end loop;
      Resolved := GNAT.OS_Lib.Locate_Exec_On_Path (Program);
      if Resolved = null then
         return False;
      end if;
      GNAT.OS_Lib.Free (Resolved);
      return True;
   end Found;

   overriding
   function Run
     (R       : in out System_Runner;
      Program : String;
      Args    : Core.Text_Lists.Vector;
      Opts    : Port.Options) return Port.Result
   is
      pragma Unreferenced (R);
      Input  : constant String :=
        (if Opts.Has_Stdin then Temp_File (To_String (Opts.Stdin))
         else "/dev/null");
      Output : constant String := Temp_File;
      Errors : constant String := Temp_File;

      procedure Clean is
      begin
         if Opts.Has_Stdin then
            Remove (Input);
         end if;
         Remove (Output);
         Remove (Errors);
      end Clean;
   begin
      if not Found (Program) then
         Clean;
         raise Port.Process_Failure with "cannot run " & Program;
      end if;

      declare
         Count  : constant Natural := Natural (Args.Length);
         Argv   : GNAT.OS_Lib.Argument_List (1 .. 8 + Count);
         Status : Integer;
      begin
         Argv (1) := new String'("-c");
         Argv (2) := new String'(Script);
         Argv (3) := new String'("sh");
         Argv (4) := new String'(To_String (Opts.Cwd));
         Argv (5) := new String'(Input);
         Argv (6) := new String'(Output);
         Argv (7) := new String'(Errors);
         Argv (8) := new String'(Program);
         for I in 1 .. Count loop
            Argv (8 + I) := new String'(To_String (Args (I)));
         end loop;

         Status := GNAT.OS_Lib.Spawn ("/bin/sh", Argv);
         for A of Argv loop
            GNAT.OS_Lib.Free (A);
         end loop;

         declare
            Result : Port.Result;
         begin
            Result.Exit_Code := Status;
            Result.Output :=
              To_Unbounded_String
                (File_Bytes.Read (Output, Port.Largest_Output));
            Result.Errors :=
              To_Unbounded_String
                (File_Bytes.Read (Errors, Port.Largest_Output));
            Clean;
            return Result;
         end;
      end;
   exception
      when File_Bytes.Too_Large =>
         Clean;
         raise Port.Process_Failure with Program & " wrote too much output";
      when Port.Process_Failure =>
         raise;
      when others =>
         Clean;
         raise;
   end Run;

end Synapse.Adapters.System_Process;
