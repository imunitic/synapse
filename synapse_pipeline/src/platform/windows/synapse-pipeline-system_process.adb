with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Unbounded;

with System;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Win32;
with Synapse.Pipeline.Windows_Programs;

package body Synapse.Pipeline.System_Process is

   use Ada.Strings.Unbounded;
   use type System.Address;
   use type Win32.DWORD;
   use type Win32.BOOL;

   package Bytes renames Synapse.Adapters.File_Bytes;

   --  The most a session may write to one stream.
   Largest_Output : constant := 64 * 1024 * 1024;

   --  What a program stopped at the time limit is given as its exit code.
   Stopped : constant Win32.C.unsigned := 1;

   --  How long a program is given to be gone once it has been stopped, in
   --  milliseconds.
   Grace_Milliseconds : constant Win32.DWORD := 5_000;

   --  The longest time limit WaitForSingleObject can be given, in seconds.
   Largest_Wait_Seconds : constant := 4_000_000;

   function Locate (Program : String) return String
   renames Windows_Programs.Locate;

   function Command_Line
     (Path : String; Arguments : Synapse.Core.Text_Lists.Vector) return String
   renames Windows_Programs.Command_Line;

   function Environment_Block
     (Extra : Synapse.Core.Text_Lists.Vector) return Wide_String
   renames Windows_Programs.Environment_Block;

   function Image (Item : Win32.DWORD) return String
   renames Windows_Programs.Image;

   procedure Close (Item : in out Win32.HANDLE)
   renames Windows_Programs.Close;

   ---------------------------------------------------------------------------
   --  Running
   ---------------------------------------------------------------------------

   procedure Remove (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Remove;

   function Not_Started (Why : String) return Session_Process.Process_Outcome
   is (Started => False, Problem => To_Unbounded_String (Why), others => <>);

   --  A file the program can read or write, for one of its three standard
   --  streams: opened so that the program inherits it.
   function Open_Stream
     (Path       : String;
      Reading    : Boolean;
      Attributes : System.Address) return Win32.HANDLE
   is
     (Win32.Create_File
        (Win32.Wide (Path),
         (if Reading then Win32.Generic_Read else Win32.Generic_Write),
         Win32.File_Share_Read or Win32.File_Share_Write,
         Attributes,
         (if Reading then Win32.Open_Existing else Win32.Create_Always),
         Win32.File_Attribute_Normal,
         System.Null_Address));

   overriding
   function Run
     (P       : in out System_Process;
      Request : Session_Process.Process_Request)
      return Session_Process.Process_Outcome
   is
      pragma Unreferenced (P);
      Program : constant String := To_String (Request.Program);
      Path    : constant String := Locate (Program);
      Input   : constant String :=
        Bytes.Temp_File (To_String (Request.Standard_Input));
      Kept    : constant Boolean := Length (Request.Output_Path) > 0;
      Output  : constant String :=
        (if Kept then To_String (Request.Output_Path) else Bytes.Temp_File);
      Errors  : constant String := Bytes.Temp_File;

      procedure Clean is
      begin
         Remove (Input);
         if not Kept then
            Remove (Output);
         end if;
         Remove (Errors);
      end Clean;
   begin
      if Path = "" then
         Clean;
         return Not_Started ("'" & Program & "' was not found");
      end if;
      declare
         Inherit    : aliased Win32.SECURITY_ATTRIBUTES :=
           (Length         => Win32.SECURITY_ATTRIBUTES'Size / 8,
            Inherit_Handle => 1,
            others         => <>);
         In_File    : Win32.HANDLE :=
           Open_Stream (Input, True, Inherit'Address);
         Out_File   : Win32.HANDLE :=
           Open_Stream (Output, False, Inherit'Address);
         Err_File   : Win32.HANDLE :=
           Open_Stream (Errors, False, Inherit'Address);
         Job        : Win32.HANDLE := System.Null_Address;
         Information : aliased Win32.PROCESS_INFORMATION;

         procedure Close_All is
         begin
            Close (Information.Thread);
            Close (Information.Process);
            Close (Job);
            Close (In_File);
            Close (Out_File);
            Close (Err_File);
         end Close_All;
      begin
         if In_File = Win32.Invalid_Handle
           or else Out_File = Win32.Invalid_Handle
           or else Err_File = Win32.Invalid_Handle
         then
            declare
               Why : constant String :=
                 "cannot prepare the standard streams of " & Program
                 & ": error " & Image (Win32.Get_Last_Error);
            begin
               Close_All;
               Clean;
               return Not_Started (Why);
            end;
         end if;
         declare
            Startup : aliased Win32.STARTUPINFOW :=
              (Size       => Win32.STARTUPINFOW'Size / 8,
               Flags      => Win32.Startf_Use_Std_Handles,
               Std_Input  => In_File,
               Std_Output => Out_File,
               Std_Error  => Err_File,
               others     => <>);
            Line    : aliased Win32.C.wchar_array :=
              Win32.Wide (Command_Line (Path, Request.Arguments));
            Block   : aliased Win32.C.wchar_array :=
              Win32.C.To_C (Environment_Block (Request.Environment));
            Where   : aliased Win32.C.wchar_array :=
              Win32.Wide (To_String (Request.Directory));
            Created : Win32.BOOL;
         begin
            Created :=
              Win32.Create_Process
                (Application        => System.Null_Address,
                 Command_Line       => Line'Address,
                 Process_Attributes => System.Null_Address,
                 Thread_Attributes  => System.Null_Address,
                 Inherit_Handles    => 1,
                 Flags              =>
                   Win32.Create_Suspended
                   or Win32.Create_Unicode_Environment
                   or Win32.Create_No_Window,
                 Environment        => Block'Address,
                 Directory          =>
                   (if Length (Request.Directory) = 0 then System.Null_Address
                    else Where'Address),
                 Startup            => Startup'Address,
                 Information        => Information'Address);
            if Created = 0 then
               declare
                  Why : constant String :=
                    "cannot run " & Path & ": error "
                    & Image (Win32.Get_Last_Error);
               begin
                  Information := (others => <>);
                  Close_All;
                  Clean;
                  return Not_Started (Why);
               end;
            end if;
         end;

         --  The program and whatever it starts are one job, so that all of
         --  it can be stopped, and it is stopped if this program goes.
         Job :=
           Win32.Create_Job_Object
             (System.Null_Address, System.Null_Address);
         declare
            Limits   : aliased Win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION :=
              (Limit_Flags => Win32.Job_Object_Limit_Kill_On_Job_Close,
               others      => <>);
            In_A_Job : Boolean := False;
            Waited   : Win32.DWORD;
            Code     : aliased Win32.DWORD := 0;
            Fetched  : Win32.BOOL;
            Timed_Out : Boolean := False;
            Ignored  : Win32.BOOL;
            Resumed  : Win32.DWORD;
         begin
            if Job /= System.Null_Address then
               In_A_Job :=
                 Win32.Set_Information_Job_Object
                   (Job, Win32.Job_Object_Extended_Limit_Information,
                    Limits'Address, Limits'Size / 8) /= 0
                 and then Win32.Assign_Process_To_Job_Object
                            (Job, Information.Process) /= 0;
            end if;

            Resumed := Win32.Resume_Thread (Information.Thread);
            if Resumed = 16#FFFF_FFFF# then
               Ignored :=
                 Win32.Terminate_Process (Information.Process, Stopped);
               Close_All;
               Clean;
               return Not_Started ("cannot start " & Path);
            end if;

            Waited :=
              Win32.Wait_For_Single_Object
                (Information.Process,
                 Win32.DWORD
                   (Natural'Min
                      (Request.Timeout_Seconds, Largest_Wait_Seconds))
                 * 1000);
            if Waited /= Win32.Wait_Object_0 then
               Timed_Out := True;
               if In_A_Job then
                  Ignored := Win32.Terminate_Job_Object (Job, Stopped);
               else
                  Ignored :=
                    Win32.Terminate_Process (Information.Process, Stopped);
               end if;
               Waited :=
                 Win32.Wait_For_Single_Object
                   (Information.Process, Grace_Milliseconds);
            end if;
            Fetched :=
              Win32.Get_Exit_Code_Process (Information.Process, Code'Address);
            Close_All;

            declare
               Done : Session_Process.Process_Outcome;
            begin
               Done.Started := True;
               Done.Exit_Code :=
                 (if Fetched /= 0 then Integer (Code mod 2 ** 31) else -1);
               Done.Timed_Out := Timed_Out;
               Done.Output :=
                 To_Unbounded_String (Bytes.Read (Output, Largest_Output));
               Done.Errors :=
                 To_Unbounded_String (Bytes.Read (Errors, Largest_Output));
               Clean;
               return Done;
            end;
         end;
      end;
   exception
      when Bytes.Too_Large =>
         --  A transcript past the limit cannot be read back: do not keep it.
         Remove (Output);
         Clean;
         return Not_Started (Program & " wrote too much output");
      when E : others =>
         Clean;
         return Not_Started (Ada.Exceptions.Exception_Message (E));
   end Run;

end Synapse.Pipeline.System_Process;
