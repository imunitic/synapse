with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

with Synapse.Adapters.File_Bytes;

package body Synapse.Pipeline.System_Process is

   use Ada.Strings.Unbounded;
   use type GNAT.OS_Lib.String_Access;

   package Bytes renames Synapse.Adapters.File_Bytes;

   --  The most a session may write to one stream.
   Largest_Output : constant := 64 * 1024 * 1024;

   --  How long a program is given to stop after it is asked to, before it
   --  is made to.
   Grace_Seconds : constant := 5;

   --  Runs in the directory in $1 (if any) with standard input from $2,
   --  standard output to $3 and standard error to $4, as a job of its own
   --  with its own process group. A watcher in a group of its own too asks
   --  the group to stop after $6 seconds, making $5 exist first, and makes it
   --  after a grace period. The shell itself says nothing. Every value reaches
   --  the script as an argument, never as shell text.
   Script : constant String :=
     "dir=$1; in=$2; out=$3; err=$4; mark=$5; limit=$6; shift 6; "
     & "if [ -n ""$dir"" ]; then cd ""$dir"" || exit 127; fi; "
     & "exec 2>/dev/null; set -m; "
     & """$@"" <""$in"" >""$out"" 2>""$err"" & pid=$!; "
     & "( sleep ""$limit""; : >""$mark""; "
     & "kill -TERM -- ""-$pid"" 2>/dev/null; "
     & "sleep" & Natural'Image (Grace_Seconds)
     & "; kill -KILL -- ""-$pid"" 2>/dev/null ) & watcher=$!; "
     & "wait ""$pid""; rc=$?; "
     & "kill -TERM -- ""-$watcher"" 2>/dev/null; exit $rc";

   function Image (Item : Positive) return String is
      Text : constant String := Positive'Image (Item);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

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

   function Not_Started (Why : String) return Session_Process.Process_Outcome
   is (Started => False, Problem => To_Unbounded_String (Why), others => <>);

   overriding
   function Run
     (P       : in out System_Process;
      Request : Session_Process.Process_Request)
      return Session_Process.Process_Outcome
   is
      pragma Unreferenced (P);
      Program : constant String := To_String (Request.Program);
      Input   : constant String :=
        Bytes.Temp_File (To_String (Request.Standard_Input));
      Output  : constant String := Bytes.Temp_File;
      Errors  : constant String := Bytes.Temp_File;
      Marker  : constant String := Bytes.Temp_File;

      procedure Clean is
      begin
         Remove (Input);
         Remove (Output);
         Remove (Errors);
         Remove (Marker);
      end Clean;
   begin
      Remove (Marker);
      if not Found (Program) then
         Clean;
         return Not_Started ("'" & Program & "' was not found");
      end if;
      declare
         Extra  : constant Natural := Natural (Request.Environment.Length);
         Count  : constant Natural := Natural (Request.Arguments.Length);
         Argv   : GNAT.OS_Lib.Argument_List (1 .. 11 + Extra + Count);
         Status : Integer;
         Next   : Positive := 11;
      begin
         Argv (1) := new String'("-c");
         Argv (2) := new String'(Script);
         Argv (3) := new String'("sh");
         Argv (4) := new String'(To_String (Request.Directory));
         Argv (5) := new String'(Input);
         Argv (6) := new String'(Output);
         Argv (7) := new String'(Errors);
         Argv (8) := new String'(Marker);
         Argv (9) := new String'(Image (Request.Timeout_Seconds));
         Argv (10) := new String'("env");
         for Entry_Text of Request.Environment loop
            Argv (Next) := new String'(To_String (Entry_Text));
            Next := Next + 1;
         end loop;
         Argv (Next) := new String'(Program);
         Next := Next + 1;
         for Arg of Request.Arguments loop
            Argv (Next) := new String'(To_String (Arg));
            Next := Next + 1;
         end loop;

         Status := GNAT.OS_Lib.Spawn ("/bin/sh", Argv (1 .. Next - 1));
         for A of Argv (1 .. Next - 1) loop
            GNAT.OS_Lib.Free (A);
         end loop;

         declare
            Done : Session_Process.Process_Outcome;
         begin
            Done.Started := True;
            Done.Exit_Code := Status;
            Done.Timed_Out := Ada.Directories.Exists (Marker);
            Done.Output :=
              To_Unbounded_String (Bytes.Read (Output, Largest_Output));
            Done.Errors :=
              To_Unbounded_String (Bytes.Read (Errors, Largest_Output));
            Clean;
            return Done;
         end;
      end;
   exception
      when Bytes.Too_Large =>
         Clean;
         return Not_Started (Program & " wrote too much output");
      when E : others =>
         Clean;
         return Not_Started (Ada.Exceptions.Exception_Message (E));
   end Run;

end Synapse.Pipeline.System_Process;
