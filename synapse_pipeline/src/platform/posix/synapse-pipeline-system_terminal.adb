with Ada.Exceptions;
with Ada.Strings.Unbounded;

with Interfaces.C;

with GNAT.OS_Lib;

package body Synapse.Pipeline.System_Terminal is

   use Ada.Strings.Unbounded;
   use type GNAT.OS_Lib.String_Access;
   use type GNAT.OS_Lib.Process_Id;
   use type Interfaces.C.int;

   package C renames Interfaces.C;

   function Wait_For
     (Pid : C.int; Status : access C.int; Options : C.int) return C.int;
   pragma Import (C, Wait_For, "waitpid");

   function Signal (Pid : C.int; Number : C.int) return C.int;
   pragma Import (C, Signal, "kill");

   No_Hang : constant C.int := 1;
   Term    : constant C.int := 15;
   Kill    : constant C.int := 9;

   --  How long a program is given to stop after it is asked to, before it
   --  is made to.
   Grace_Seconds : constant := 5;

   --  Goes to the directory in $1 (if any) and runs the rest, in place of the
   --  shell, so that the program is the process that was started. Every value
   --  reaches the script as an argument, never as shell text.
   Script : constant String :=
     "if [ -n ""$1"" ]; then cd ""$1"" || exit 127; fi; shift; exec ""$@""";

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

   function Not_Started (Why : String) return Terminal_Process.Launch is
     (Started => False, Problem => To_Unbounded_String (Why));

   overriding
   function Start
     (T       : in out System_Terminal;
      Request : Session_Process.Process_Request)
      return Terminal_Process.Launch
   is
      pragma Unreferenced (T);
      Program : constant String := To_String (Request.Program);
   begin
      if not Found (Program) then
         return Not_Started ("'" & Program & "' was not found");
      end if;
      declare
         Extra  : constant Natural := Natural (Request.Environment.Length);
         Count  : constant Natural := Natural (Request.Arguments.Length);
         Argv   : GNAT.OS_Lib.Argument_List (1 .. 6 + Extra + Count);
         Next   : Positive := 6;
         Pid    : GNAT.OS_Lib.Process_Id;
      begin
         Argv (1) := new String'("-c");
         Argv (2) := new String'(Script);
         Argv (3) := new String'("sh");
         Argv (4) := new String'(To_String (Request.Directory));
         Argv (5) := new String'("env");
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

         Pid :=
           GNAT.OS_Lib.Non_Blocking_Spawn ("/bin/sh", Argv (1 .. Next - 1));
         for A of Argv (1 .. Next - 1) loop
            GNAT.OS_Lib.Free (A);
         end loop;
         if Pid = GNAT.OS_Lib.Invalid_Pid then
            return Not_Started ("cannot start " & Program);
         end if;
         return (Started => True,
                 Id      => Terminal_Process.Handle
                              (GNAT.OS_Lib.Pid_To_Integer (Pid)));
      end;
   exception
      when E : others =>
         return Not_Started (Ada.Exceptions.Exception_Message (E));
   end Start;

   --  How a program that ended by the status the system gave came to.
   function Progress_Of (Status : C.int) return Terminal_Process.Progress is
      Signaled : constant C.int := Status mod 128;
   begin
      if Signaled = 0 then
         return (Running   => False,
                 Exit_Code => Integer ((Status / 256) mod 256));
      end if;
      return (Running => False, Exit_Code => 128 + Integer (Signaled));
   end Progress_Of;

   overriding
   function Look
     (T  : in out System_Terminal;
      Id : Terminal_Process.Handle) return Terminal_Process.Progress
   is
      Status : aliased C.int := 0;
   begin
      if T.Ended.Contains (Id) then
         return (Running => False, Exit_Code => T.Ended.Element (Id));
      end if;
      declare
         Result : constant C.int :=
           Wait_For (C.int (Id), Status'Access, No_Hang);
      begin
         if Result = 0 then
            return (Running => True);
         end if;
         declare
            Done : constant Terminal_Process.Progress :=
              (if Result < 0 then (Running => False, Exit_Code => 1)
               else Progress_Of (Status));
         begin
            T.Ended.Insert (Id, Done.Exit_Code);
            return Done;
         end;
      end;
   end Look;

   overriding
   procedure Stop
     (T  : in out System_Terminal;
      Id : Terminal_Process.Handle)
   is
      Status : aliased C.int := 0;
   begin
      if T.Ended.Contains (Id) or else Signal (C.int (Id), Term) /= 0 then
         return;
      end if;
      for Tenth in 1 .. Grace_Seconds * 10 loop
         delay 0.1;
         if not Look (T, Id).Running then
            return;
         end if;
      end loop;
      if Signal (C.int (Id), Kill) = 0
        and then Wait_For (C.int (Id), Status'Access, 0) >= 0
      then
         T.Ended.Insert (Id, Progress_Of (Status).Exit_Code);
      end if;
   end Stop;

end Synapse.Pipeline.System_Terminal;
