with Ada.Directories;
with Ada.Strings.Fixed;

with Interfaces.C;

--  GNAT's own record of the target triple: the only place the operating
--  system's name is available to Ada code.
pragma Warnings (Off, "internal GNAT unit");
with System.OS_Constants;
pragma Warnings (On, "internal GNAT unit");

package body Synapse.Adapters.Dynamic_Libraries is

   use type System.Address;

   RTLD_NOW : constant := 2;

   function dlopen
     (File : Interfaces.C.char_array; Flags : Interfaces.C.int)
      return System.Address
   with Import, Convention => C, External_Name => "dlopen";

   function dlsym
     (Handle : System.Address; Name : Interfaces.C.char_array)
      return System.Address
   with Import, Convention => C, External_Name => "dlsym";

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
         Handle : constant System.Address :=
           dlopen (Interfaces.C.To_C (Path), RTLD_NOW);
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
      return dlsym (Handle, Interfaces.C.To_C (Name));
   end Symbol;

   overriding
   function Extension (L : System_Loader) return String is
      pragma Unreferenced (L);
   begin
      return
        (if Ada.Strings.Fixed.Index (System.OS_Constants.Target_Name, "darwin")
            > 0
         then "dylib"
         else "so");
   end Extension;

end Synapse.Adapters.Dynamic_Libraries;
