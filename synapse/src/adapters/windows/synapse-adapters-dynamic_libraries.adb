with Ada.Directories;
with Ada.Strings.UTF_Encoding.Conversions;

with Interfaces.C;

package body Synapse.Adapters.Dynamic_Libraries is

   use type System.Address;

   function LoadLibraryW
     (File : Interfaces.C.wchar_array) return System.Address
   with Import, Convention => Stdcall, External_Name => "LoadLibraryW";

   function GetProcAddress
     (Module : System.Address; Name : Interfaces.C.char_array)
      return System.Address
   with Import, Convention => Stdcall, External_Name => "GetProcAddress";

   overriding
   procedure Open
     (L      : in out System_Loader;
      Path   : String;
      Lib    : out Port.Library;
      Status : out Port.Open_Status)
   is
      pragma Unreferenced (L);
      Exists : Boolean;
   begin
      Lib := Port.No_Library;
      begin
         Exists := Ada.Directories.Exists (Path);
      exception
         when Ada.Directories.Name_Error =>
            Exists := False;
      end;
      if not Exists then
         Status := Port.Not_Found;
         return;
      end if;

      declare
         Wide   : constant Wide_String :=
           Ada.Strings.UTF_Encoding.Conversions.Convert
             (Ada.Strings.UTF_Encoding.UTF_8_String (Path));
         Handle : constant System.Address :=
           LoadLibraryW (Interfaces.C.To_C (Wide));
      begin
         if Handle = System.Null_Address then
            Status := Port.Not_A_Library;
         else
            Lib := Port.To_Library (Handle);
            Status := Port.Opened;
         end if;
      end;
   end Open;

   overriding
   function Symbol
     (L : System_Loader; Lib : Port.Library; Name : String)
      return System.Address
   is
      pragma Unreferenced (L);
      Handle : constant System.Address := Port.Handle_Of (Lib);
   begin
      if Handle = System.Null_Address then
         return System.Null_Address;
      end if;
      return GetProcAddress (Handle, Interfaces.C.To_C (Name));
   end Symbol;

   overriding
   function Extension (L : System_Loader) return String is
      pragma Unreferenced (L);
   begin
      return "dll";
   end Extension;

end Synapse.Adapters.Dynamic_Libraries;
