with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Strings.UTF_Encoding.Conversions;

with Interfaces.C;

with System;

with Synapse.Adapters.File_Bytes;

package body Synapse.Adapters.System_Process is

   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type Interfaces.C.unsigned_long;

   type Security_Attributes is record
      Length              : Interfaces.C.unsigned_long :=
        Security_Attributes'Size / System.Storage_Unit;
      Security_Descriptor : System.Address := System.Null_Address;
      Inherit_Handle      : Interfaces.C.int := 1;
   end record
   with Convention => C;

   type Startup_Info is record
      Cb              : Interfaces.C.unsigned_long :=
        Startup_Info'Size / System.Storage_Unit;
      Reserved        : System.Address := System.Null_Address;
      Desktop         : System.Address := System.Null_Address;
      Title           : System.Address := System.Null_Address;
      X, Y            : Interfaces.C.unsigned_long := 0;
      X_Size, Y_Size  : Interfaces.C.unsigned_long := 0;
      X_Chars         : Interfaces.C.unsigned_long := 0;
      Y_Chars         : Interfaces.C.unsigned_long := 0;
      Fill_Attribute  : Interfaces.C.unsigned_long := 0;
      Flags           : Interfaces.C.unsigned_long := 0;
      Show_Window     : Interfaces.C.unsigned_short := 0;
      Reserved_2      : Interfaces.C.unsigned_short := 0;
      Reserved_3      : System.Address := System.Null_Address;
      Std_Input       : System.Address := System.Null_Address;
      Std_Output      : System.Address := System.Null_Address;
      Std_Error       : System.Address := System.Null_Address;
   end record
   with Convention => C;

   type Process_Information is record
      Process    : System.Address := System.Null_Address;
      Thread     : System.Address := System.Null_Address;
      Process_Id : Interfaces.C.unsigned_long := 0;
      Thread_Id  : Interfaces.C.unsigned_long := 0;
   end record
   with Convention => C;

   STARTF_USESTDHANDLES : constant Interfaces.C.unsigned_long := 16#100#;
   CREATE_NO_WINDOW     : constant Interfaces.C.unsigned_long := 16#0800_0000#;
   GENERIC_READ         : constant Interfaces.C.unsigned_long := 16#8000_0000#;
   GENERIC_WRITE        : constant Interfaces.C.unsigned_long := 16#4000_0000#;
   FILE_SHARE_READ      : constant Interfaces.C.unsigned_long := 1;
   FILE_SHARE_WRITE     : constant Interfaces.C.unsigned_long := 2;
   CREATE_ALWAYS        : constant Interfaces.C.unsigned_long := 2;
   OPEN_EXISTING        : constant Interfaces.C.unsigned_long := 3;
   INFINITE             : constant Interfaces.C.unsigned_long := 16#FFFF_FFFF#;

   function CreateFileW
     (Name        : Interfaces.C.wchar_array;
      Access_Mode : Interfaces.C.unsigned_long;
      Share_Mode  : Interfaces.C.unsigned_long;
      Security    : access Security_Attributes;
      Disposition : Interfaces.C.unsigned_long;
      Flags       : Interfaces.C.unsigned_long;
      Template    : System.Address) return System.Address
   with Import, Convention => Stdcall, External_Name => "CreateFileW";

   function CreateProcessW
     (Application : System.Address;
      Command     : System.Address;
      Process_Sec : System.Address;
      Thread_Sec  : System.Address;
      Inherit     : Interfaces.C.int;
      Flags       : Interfaces.C.unsigned_long;
      Environment : System.Address;
      Directory   : System.Address;
      Startup     : access Startup_Info;
      Info        : access Process_Information) return Interfaces.C.int
   with Import, Convention => Stdcall, External_Name => "CreateProcessW";

   function WaitForSingleObject
     (Handle : System.Address; Milliseconds : Interfaces.C.unsigned_long)
      return Interfaces.C.unsigned_long
   with Import, Convention => Stdcall, External_Name => "WaitForSingleObject";

   function GetExitCodeProcess
     (Handle : System.Address; Code : access Interfaces.C.unsigned_long)
      return Interfaces.C.int
   with Import, Convention => Stdcall, External_Name => "GetExitCodeProcess";

   function CloseHandle (Handle : System.Address) return Interfaces.C.int
   with Import, Convention => Stdcall, External_Name => "CloseHandle";

   function Wide (Text : String) return Interfaces.C.wchar_array
   is (Interfaces.C.To_C
         (Ada.Strings.UTF_Encoding.Conversions.Convert
            (Ada.Strings.UTF_Encoding.UTF_8_String (Text))));

   --  One argument quoted so that the Microsoft C runtime reads it back as
   --  it is: quotes around anything with a blank, a quote or nothing, a
   --  backslash run before a quote doubled, and a quote escaped.
   function Quote (Argument : String) return String is
      Needs  : constant Boolean :=
        Argument'Length = 0
        or else (for some C of Argument => C in ' ' | Character'Val (9)
                                               | Character'Val (10) | '"');
      Result : Unbounded_String;
      Slashes : Natural := 0;
   begin
      if not Needs then
         return Argument;
      end if;
      Append (Result, '"');
      for C of Argument loop
         if C = '\' then
            Slashes := Slashes + 1;
         elsif C = '"' then
            Append (Result, [1 .. 2 * Slashes + 1 => '\']);
            Append (Result, '"');
            Slashes := 0;
         else
            Append (Result, [1 .. Slashes => '\']);
            Append (Result, C);
            Slashes := 0;
         end if;
      end loop;
      Append (Result, [1 .. 2 * Slashes => '\']);
      Append (Result, '"');
      return To_String (Result);
   end Quote;

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

   --  A handle on Path, for reading or for writing, that the child inherits.
   function Open_Inheritable (Path : String; Writing : Boolean)
      return System.Address
   is
      Security : aliased Security_Attributes;
   begin
      return
        CreateFileW
          (Wide (Path),
           (if Writing then GENERIC_WRITE else GENERIC_READ),
           FILE_SHARE_READ + FILE_SHARE_WRITE,
           Security'Access,
           (if Writing then CREATE_ALWAYS else OPEN_EXISTING),
           0,
           System.Null_Address);
   end Open_Inheritable;

   overriding
   function Run
     (R       : in out System_Runner;
      Program : String;
      Args    : Core.Text_Lists.Vector;
      Opts    : Port.Options) return Port.Result
   is
      pragma Unreferenced (R);
      Input  : constant String := Temp_File (To_String (Opts.Stdin));
      Output : constant String := Temp_File;
      Errors : constant String := Temp_File;

      procedure Clean is
      begin
         Remove (Input);
         Remove (Output);
         Remove (Errors);
      end Clean;

      Command : Unbounded_String := To_Unbounded_String (Quote (Program));
   begin
      for Argument of Args loop
         Append (Command, " " & Quote (To_String (Argument)));
      end loop;

      declare
         In_Handle  : constant System.Address :=
           Open_Inheritable (Input, False);
         Out_Handle : constant System.Address :=
           Open_Inheritable (Output, True);
         Err_Handle : constant System.Address :=
           Open_Inheritable (Errors, True);
         Startup    : aliased Startup_Info;
         Info       : aliased Process_Information;
         Line       : Interfaces.C.wchar_array :=
           Wide (To_String (Command));
         Directory  : constant Interfaces.C.wchar_array :=
           Wide (To_String (Opts.Cwd));
         Code       : aliased Interfaces.C.unsigned_long := 0;
         Ignore     : Interfaces.C.int;
         Waited     : Interfaces.C.unsigned_long;
         pragma Unreferenced (Ignore, Waited);
      begin
         Startup.Flags := STARTF_USESTDHANDLES;
         Startup.Std_Input := In_Handle;
         Startup.Std_Output := Out_Handle;
         Startup.Std_Error := Err_Handle;

         if CreateProcessW
              (System.Null_Address, Line (Line'First)'Address,
               System.Null_Address, System.Null_Address, 1, CREATE_NO_WINDOW,
               System.Null_Address,
               (if Length (Opts.Cwd) = 0 then System.Null_Address
                else Directory (Directory'First)'Address),
               Startup'Access, Info'Access) = 0
         then
            Ignore := CloseHandle (In_Handle);
            Ignore := CloseHandle (Out_Handle);
            Ignore := CloseHandle (Err_Handle);
            Clean;
            raise Port.Process_Failure with "cannot run " & Program;
         end if;

         Waited := WaitForSingleObject (Info.Process, INFINITE);
         Ignore := GetExitCodeProcess (Info.Process, Code'Access);
         Ignore := CloseHandle (Info.Process);
         Ignore := CloseHandle (Info.Thread);
         Ignore := CloseHandle (In_Handle);
         Ignore := CloseHandle (Out_Handle);
         Ignore := CloseHandle (Err_Handle);

         declare
            Result : Port.Result;
         begin
            Result.Exit_Code := Integer (Code);
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
