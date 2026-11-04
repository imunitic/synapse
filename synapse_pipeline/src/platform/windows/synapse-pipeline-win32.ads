with Interfaces.C;
with System;
with System.Storage_Elements;

--  The parts of the Windows API the pipeline's Windows adapters call, in one
--  place. Every name is Windows's own, spelled the way Ada reads best; every
--  function is imported as it is declared in the Windows headers.

package Synapse.Pipeline.Win32 is

   package C renames Interfaces.C;

   subtype DWORD is C.unsigned_long;
   subtype BOOL is C.int;
   subtype HANDLE is System.Address;

   Invalid_Handle : constant HANDLE :=
     System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address'Last);

   --  The wide string the Windows API takes for Text, ended by a nul.
   function Wide (Text : String) return C.wchar_array;

   --  The text of a wide string that ends at its first nul.
   function Narrow (Text : C.wchar_array) return String;

   ---------------------------------------------------------------------------
   --  Constants
   ---------------------------------------------------------------------------

   Generic_Read          : constant DWORD := 16#8000_0000#;
   Generic_Write         : constant DWORD := 16#4000_0000#;
   Open_Existing         : constant DWORD := 3;
   Create_Always         : constant DWORD := 2;
   File_Flag_Overlapped  : constant DWORD := 16#4000_0000#;
   File_Attribute_Normal : constant DWORD := 16#80#;
   File_Share_Read       : constant DWORD := 1;
   File_Share_Write      : constant DWORD := 2;

   Pipe_Access_Duplex    : constant DWORD := 3;
   Pipe_Wait             : constant DWORD := 0;
   Pipe_Reject_Remote    : constant DWORD := 8;

   Wait_Object_0         : constant DWORD := 0;
   Wait_Timeout          : constant DWORD := 16#102#;
   Infinite              : constant DWORD := 16#FFFF_FFFF#;

   Create_Suspended          : constant DWORD := 16#4#;
   Create_Unicode_Environment : constant DWORD := 16#400#;
   Create_No_Window          : constant DWORD := 16#800_0000#;
   Startf_Use_Std_Handles    : constant DWORD := 16#100#;

   Job_Object_Extended_Limit_Information : constant C.int := 9;
   Job_Object_Limit_Kill_On_Job_Close    : constant DWORD := 16#2000#;

   Error_Broken_Pipe     : constant DWORD := 109;
   Error_Pipe_Busy       : constant DWORD := 231;
   Error_Pipe_Connected  : constant DWORD := 535;
   Error_Io_Pending      : constant DWORD := 997;
   Error_Operation_Aborted : constant DWORD := 995;

   ---------------------------------------------------------------------------
   --  Types
   ---------------------------------------------------------------------------

   type OVERLAPPED is record
      Internal      : C.size_t := 0;
      Internal_High : C.size_t := 0;
      Offset        : DWORD := 0;
      Offset_High   : DWORD := 0;
      Event         : HANDLE := System.Null_Address;
   end record
   with Convention => C;

   type SECURITY_ATTRIBUTES is record
      Length              : DWORD := 0;
      Security_Descriptor : System.Address := System.Null_Address;
      Inherit_Handle      : BOOL := 0;
   end record
   with Convention => C;

   type STARTUPINFOW is record
      Size            : DWORD := 0;
      Reserved        : System.Address := System.Null_Address;
      Desktop         : System.Address := System.Null_Address;
      Title           : System.Address := System.Null_Address;
      X               : DWORD := 0;
      Y               : DWORD := 0;
      X_Size          : DWORD := 0;
      Y_Size          : DWORD := 0;
      X_Count_Chars   : DWORD := 0;
      Y_Count_Chars   : DWORD := 0;
      Fill_Attribute  : DWORD := 0;
      Flags           : DWORD := 0;
      Show_Window     : C.unsigned_short := 0;
      Reserved_2_Size : C.unsigned_short := 0;
      Reserved_2      : System.Address := System.Null_Address;
      Std_Input       : HANDLE := System.Null_Address;
      Std_Output      : HANDLE := System.Null_Address;
      Std_Error       : HANDLE := System.Null_Address;
   end record
   with Convention => C;

   type PROCESS_INFORMATION is record
      Process    : HANDLE := System.Null_Address;
      Thread     : HANDLE := System.Null_Address;
      Process_Id : DWORD := 0;
      Thread_Id  : DWORD := 0;
   end record
   with Convention => C;

   type Counter_Array is array (1 .. 6) of C.unsigned_long_long
   with Convention => C;

   --  JOBOBJECT_EXTENDED_LIMIT_INFORMATION, of which only the flags matter.
   type JOBOBJECT_EXTENDED_LIMIT_INFORMATION is record
      Per_Process_User_Time : C.long_long := 0;
      Per_Job_User_Time     : C.long_long := 0;
      Limit_Flags           : DWORD := 0;
      Minimum_Working_Set   : C.size_t := 0;
      Maximum_Working_Set   : C.size_t := 0;
      Active_Process_Limit  : DWORD := 0;
      Affinity              : C.size_t := 0;
      Priority_Class        : DWORD := 0;
      Scheduling_Class      : DWORD := 0;
      Io_Counters           : Counter_Array := [others => 0];
      Process_Memory_Limit  : C.size_t := 0;
      Job_Memory_Limit      : C.size_t := 0;
      Peak_Process_Memory   : C.size_t := 0;
      Peak_Job_Memory       : C.size_t := 0;
   end record
   with Convention => C;

   type FILETIME is record
      Low  : DWORD := 0;
      High : DWORD := 0;
   end record
   with Convention => C;

   type WIN32_FIND_DATAW is record
      Attributes     : DWORD := 0;
      Created        : FILETIME;
      Accessed       : FILETIME;
      Written        : FILETIME;
      Size_High      : DWORD := 0;
      Size_Low       : DWORD := 0;
      Reserved_0     : DWORD := 0;
      Reserved_1     : DWORD := 0;
      File_Name      : C.wchar_array (0 .. 259) := [others => C.wide_nul];
      Alternate_Name : C.wchar_array (0 .. 13) := [others => C.wide_nul];
   end record
   with Convention => C;

   ---------------------------------------------------------------------------
   --  Functions
   ---------------------------------------------------------------------------

   function Get_Last_Error return DWORD
   with Import, Convention => Stdcall, External_Name => "GetLastError";

   function Close_Handle (Item : HANDLE) return BOOL
   with Import, Convention => Stdcall, External_Name => "CloseHandle";

   function Create_Event
     (Attributes   : System.Address;
      Manual_Reset : BOOL;
      Initial      : BOOL;
      Name         : System.Address) return HANDLE
   with Import, Convention => Stdcall, External_Name => "CreateEventW";

   function Reset_Event (Item : HANDLE) return BOOL
   with Import, Convention => Stdcall, External_Name => "ResetEvent";

   function Wait_For_Single_Object
     (Item : HANDLE; Milliseconds : DWORD) return DWORD
   with Import, Convention => Stdcall, External_Name => "WaitForSingleObject";

   function Create_Named_Pipe
     (Name          : C.wchar_array;
      Open_Mode     : DWORD;
      Pipe_Mode     : DWORD;
      Max_Instances : DWORD;
      Out_Size      : DWORD;
      In_Size       : DWORD;
      Default_Wait  : DWORD;
      Security      : System.Address) return HANDLE
   with Import, Convention => Stdcall, External_Name => "CreateNamedPipeW";

   function Connect_Named_Pipe
     (Pipe : HANDLE; Overlapped : System.Address) return BOOL
   with Import, Convention => Stdcall, External_Name => "ConnectNamedPipe";

   function Disconnect_Named_Pipe (Pipe : HANDLE) return BOOL
   with Import, Convention => Stdcall, External_Name => "DisconnectNamedPipe";

   function Wait_Named_Pipe
     (Name : C.wchar_array; Milliseconds : DWORD) return BOOL
   with Import, Convention => Stdcall, External_Name => "WaitNamedPipeW";

   function Create_File
     (Name        : C.wchar_array;
      Access_Mode : DWORD;
      Share_Mode  : DWORD;
      Security    : System.Address;
      Creation    : DWORD;
      Flags       : DWORD;
      Template    : HANDLE) return HANDLE
   with Import, Convention => Stdcall, External_Name => "CreateFileW";

   function Read_File
     (File       : HANDLE;
      Buffer     : System.Address;
      Size       : DWORD;
      Done       : System.Address;
      Overlapped : System.Address) return BOOL
   with Import, Convention => Stdcall, External_Name => "ReadFile";

   function Write_File
     (File       : HANDLE;
      Buffer     : System.Address;
      Size       : DWORD;
      Done       : System.Address;
      Overlapped : System.Address) return BOOL
   with Import, Convention => Stdcall, External_Name => "WriteFile";

   function Get_Overlapped_Result
     (File       : HANDLE;
      Overlapped : System.Address;
      Transferred : System.Address;
      Wait       : BOOL) return BOOL
   with Import, Convention => Stdcall, External_Name => "GetOverlappedResult";

   function Cancel_Io_Ex
     (File : HANDLE; Overlapped : System.Address) return BOOL
   with Import, Convention => Stdcall, External_Name => "CancelIoEx";

   function Get_Environment_Strings return System.Address
   with Import, Convention => Stdcall,
        External_Name => "GetEnvironmentStringsW";

   function Free_Environment_Strings (Block : System.Address) return BOOL
   with Import, Convention => Stdcall,
        External_Name => "FreeEnvironmentStringsW";

   function Create_Process
     (Application  : System.Address;
      Command_Line : System.Address;
      Process_Attributes : System.Address;
      Thread_Attributes  : System.Address;
      Inherit_Handles    : BOOL;
      Flags              : DWORD;
      Environment        : System.Address;
      Directory          : System.Address;
      Startup            : System.Address;
      Information        : System.Address) return BOOL
   with Import, Convention => Stdcall, External_Name => "CreateProcessW";

   function Create_Job_Object
     (Attributes : System.Address; Name : System.Address) return HANDLE
   with Import, Convention => Stdcall, External_Name => "CreateJobObjectW";

   function Set_Information_Job_Object
     (Job    : HANDLE;
      Class  : C.int;
      Info   : System.Address;
      Length : DWORD) return BOOL
   with Import, Convention => Stdcall,
        External_Name => "SetInformationJobObject";

   function Assign_Process_To_Job_Object
     (Job : HANDLE; Process : HANDLE) return BOOL
   with Import, Convention => Stdcall,
        External_Name => "AssignProcessToJobObject";

   function Terminate_Job_Object
     (Job : HANDLE; Exit_Code : C.unsigned) return BOOL
   with Import, Convention => Stdcall, External_Name => "TerminateJobObject";

   function Terminate_Process
     (Process : HANDLE; Exit_Code : C.unsigned) return BOOL
   with Import, Convention => Stdcall, External_Name => "TerminateProcess";

   function Resume_Thread (Thread : HANDLE) return DWORD
   with Import, Convention => Stdcall, External_Name => "ResumeThread";

   function Get_Exit_Code_Process
     (Process : HANDLE; Code : System.Address) return BOOL
   with Import, Convention => Stdcall, External_Name => "GetExitCodeProcess";

   function Find_First_File
     (Pattern : C.wchar_array; Data : System.Address) return HANDLE
   with Import, Convention => Stdcall, External_Name => "FindFirstFileW";

   function Find_Next_File
     (Search : HANDLE; Data : System.Address) return BOOL
   with Import, Convention => Stdcall, External_Name => "FindNextFileW";

   function Find_Close (Search : HANDLE) return BOOL
   with Import, Convention => Stdcall, External_Name => "FindClose";

end Synapse.Pipeline.Win32;
