with Ada.Exceptions;
with Ada.Strings.Unbounded;

with Synapse.Pipeline.Win32;
with Synapse.Pipeline.Windows_Programs;

package body Synapse.Pipeline.System_Terminal is

   use Ada.Strings.Unbounded;
   use type System.Address;
   use type Win32.DWORD;
   use type Win32.BOOL;

   package Programs renames Windows_Programs;

   --  CreateProcess takes a command line of at most 32,767 characters.
   Longest_Command_Line : constant := 32_000;

   --  What a program stopped by this program is given as its exit code.
   Stopped : constant Win32.C.unsigned := 1;

   --  How long a program is given to be gone once it has been stopped.
   Grace_Milliseconds : constant Win32.DWORD := 5_000;

   function Not_Started (Why : String) return Terminal_Process.Launch is
     (Started => False, Problem => To_Unbounded_String (Why));

   --  A harness that is stopped hard can leave the console in the mode its
   --  screen drawing set, so the modes are kept when a program starts and
   --  given back when it ends.
   procedure Save_Console (T : in out System_Terminal) is
      Mode_In  : aliased Win32.DWORD := 0;
      Mode_Out : aliased Win32.DWORD := 0;
   begin
      if Win32.Get_Console_Mode
           (Win32.Get_Std_Handle (Win32.Std_Input_Handle), Mode_In'Address)
         /= 0
      then
         T.Console_Input := Integer (Mode_In);
      end if;
      if Win32.Get_Console_Mode
           (Win32.Get_Std_Handle (Win32.Std_Output_Handle), Mode_Out'Address)
         /= 0
      then
         T.Console_Output := Integer (Mode_Out);
      end if;
   end Save_Console;

   procedure Restore_Console (T : in out System_Terminal) is
      Ignored : Win32.BOOL;
   begin
      if T.Console_Input >= 0 then
         Ignored :=
           Win32.Set_Console_Mode
             (Win32.Get_Std_Handle (Win32.Std_Input_Handle),
              Win32.DWORD (T.Console_Input));
      end if;
      if T.Console_Output >= 0 then
         Ignored :=
           Win32.Set_Console_Mode
             (Win32.Get_Std_Handle (Win32.Std_Output_Handle),
              Win32.DWORD (T.Console_Output));
      end if;
      T.Console_Input := -1;
      T.Console_Output := -1;
   end Restore_Console;

   --  The program Id has ended with Code: its handles are let go, which
   --  also ends anything it started that is left, and the console is given
   --  back.
   procedure Finish
     (T : in out System_Terminal; Id : Terminal_Process.Handle; Code : Integer)
   is
      Held : Live_Process := T.Live.Element (Id);
   begin
      Programs.Close (Held.Process);
      Programs.Close (Held.Job);
      T.Live.Delete (Id);
      T.Ended.Include (Id, Code);
      Restore_Console (T);
   end Finish;

   overriding
   function Start
     (T       : in out System_Terminal;
      Request : Session_Process.Process_Request)
      return Terminal_Process.Launch
   is
      Program : constant String := To_String (Request.Program);
      Path    : constant String := Programs.Locate (Program);
   begin
      if Path = "" then
         return Not_Started ("'" & Program & "' was not found");
      end if;
      declare
         Text : constant String :=
           Programs.Command_Line (Path, Request.Arguments);
      begin
         if Text'Length > Longest_Command_Line then
            return Not_Started
              ("the command line of " & Program & " is"
               & Natural'Image (Text'Length)
               & " characters, more than Windows takes: the prompt is too "
               & "long to give as an argument");
         end if;
         declare
            --  No standard streams are given: the program is in this
            --  program's console and uses it.
            Startup     : aliased Win32.STARTUPINFOW :=
              (Size => Win32.STARTUPINFOW'Size / 8, others => <>);
            Information : aliased Win32.PROCESS_INFORMATION;
            Line        : aliased Win32.C.wchar_array := Win32.Wide (Text);
            Block       : aliased Win32.C.wchar_array :=
              Win32.C.To_C (Programs.Environment_Block (Request.Environment));
            Where       : aliased Win32.C.wchar_array :=
              Win32.Wide (To_String (Request.Directory));
            Created     : Win32.BOOL;
         begin
            Save_Console (T);
            Created :=
              Win32.Create_Process
                (Application        => System.Null_Address,
                 Command_Line       => Line'Address,
                 Process_Attributes => System.Null_Address,
                 Thread_Attributes  => System.Null_Address,
                 Inherit_Handles    => 0,
                 Flags              =>
                   Win32.Create_Suspended or Win32.Create_Unicode_Environment,
                 Environment        => Block'Address,
                 Directory          =>
                   (if Length (Request.Directory) = 0 then System.Null_Address
                    else Where'Address),
                 Startup            => Startup'Address,
                 Information        => Information'Address);
            if Created = 0 then
               T.Console_Input := -1;
               T.Console_Output := -1;
               return Not_Started
                 ("cannot run " & Path & ": error "
                  & Programs.Image (Win32.Get_Last_Error));
            end if;

            --  The program and whatever it starts are one job, so that all
            --  of it can be stopped, and it is stopped if this program goes.
            declare
               Job      : Win32.HANDLE :=
                 Win32.Create_Job_Object
                   (System.Null_Address, System.Null_Address);
               Limits   : aliased Win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION :=
                 (Limit_Flags => Win32.Job_Object_Limit_Kill_On_Job_Close,
                  others      => <>);
               In_A_Job : Boolean := False;
               Resumed  : Win32.DWORD;
               Ignored  : Win32.BOOL;
            begin
               if Job /= System.Null_Address then
                  In_A_Job :=
                    Win32.Set_Information_Job_Object
                      (Job, Win32.Job_Object_Extended_Limit_Information,
                       Limits'Address, Limits'Size / 8) /= 0
                    and then Win32.Assign_Process_To_Job_Object
                               (Job, Information.Process) /= 0;
                  if not In_A_Job then
                     Programs.Close (Job);
                  end if;
               end if;
               Resumed := Win32.Resume_Thread (Information.Thread);
               if Resumed = 16#FFFF_FFFF# then
                  Ignored :=
                    Win32.Terminate_Process (Information.Process, Stopped);
                  Programs.Close (Information.Thread);
                  Programs.Close (Information.Process);
                  Programs.Close (Job);
                  T.Console_Input := -1;
                  T.Console_Output := -1;
                  return Not_Started ("cannot start " & Path);
               end if;
               Programs.Close (Information.Thread);
               declare
                  Id : constant Terminal_Process.Handle :=
                    Terminal_Process.Handle (Information.Process_Id);
               begin
                  T.Live.Include
                    (Id, (Process => Information.Process, Job => Job));
                  return (Started => True, Id => Id);
               end;
            end;
         end;
      end;
   exception
      when E : others =>
         return Not_Started (Ada.Exceptions.Exception_Message (E));
   end Start;

   overriding
   function Look
     (T  : in out System_Terminal;
      Id : Terminal_Process.Handle) return Terminal_Process.Progress is
   begin
      if T.Ended.Contains (Id) then
         return (Running => False, Exit_Code => T.Ended.Element (Id));
      elsif not T.Live.Contains (Id) then
         return (Running => False, Exit_Code => 1);
      end if;
      declare
         Held   : constant Live_Process := T.Live.Element (Id);
         Waited : constant Win32.DWORD :=
           Win32.Wait_For_Single_Object (Held.Process, 0);
      begin
         if Waited = Win32.Wait_Timeout then
            return (Running => True);
         end if;
         declare
            Code    : aliased Win32.DWORD := 0;
            Fetched : constant Win32.BOOL :=
              Win32.Get_Exit_Code_Process (Held.Process, Code'Address);
            Result  : constant Integer :=
              (if Waited = Win32.Wait_Object_0 and then Fetched /= 0
               then Integer (Code mod 2 ** 31) else 1);
         begin
            Finish (T, Id, Result);
            return (Running => False, Exit_Code => Result);
         end;
      end;
   end Look;

   overriding
   procedure Stop
     (T  : in out System_Terminal;
      Id : Terminal_Process.Handle) is
   begin
      if T.Ended.Contains (Id) or else not T.Live.Contains (Id) then
         return;
      end if;
      declare
         Held    : constant Live_Process := T.Live.Element (Id);
         Ignored : Win32.BOOL;
         Waited  : Win32.DWORD;
      begin
         --  A console program has no gentler signal than being ended.
         if Held.Job /= System.Null_Address then
            Ignored := Win32.Terminate_Job_Object (Held.Job, Stopped);
         else
            Ignored := Win32.Terminate_Process (Held.Process, Stopped);
         end if;
         Waited :=
           Win32.Wait_For_Single_Object (Held.Process, Grace_Milliseconds);
         pragma Unreferenced (Waited);
         --  Told, so that its end is kept and its handles are let go.
         if Look (T, Id).Running then
            null;
         end if;
      end;
   end Stop;

end Synapse.Pipeline.System_Terminal;
