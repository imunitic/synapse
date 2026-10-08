--  Loading of shared libraries and resolving their symbols: what grammar
--  loading needs from the operating system. Implementations live under
--  Synapse.Adapters.

with System;

package Synapse.Ports.Library_Loader is

   --  A loaded library. Libraries stay loaded for the life of the process:
   --  addresses resolved from them are used until it exits.
   type Library is private;

   No_Library : constant Library;

   type Open_Status is (Opened, Not_Found, Not_A_Library);

   type Loader is limited interface;

   --  Not_Found: nothing exists at Path. Not_A_Library: something does, but it
   --  could not be loaded as a shared library.
   procedure Open
     (L      : in out Loader;
      Path   : String;
      Lib    : out Library;
      Status : out Open_Status)
   is abstract;

   --  The address of Name in Lib; System.Null_Address when there is none.
   function Symbol
     (L : Loader; Lib : Library; Name : String) return System.Address
   is abstract;

   --  The file extension shared libraries carry on this system, without the
   --  dot: "so", "dylib" or "dll".
   function Extension (L : Loader) return String is abstract;

   --  For adapters: wrap and unwrap the system's own handle.
   function To_Library (Handle : System.Address) return Library;

   function Handle_Of (Lib : Library) return System.Address;

private

   type Library is record
      Handle : System.Address := System.Null_Address;
   end record;

   No_Library : constant Library := (Handle => System.Null_Address);

end Synapse.Ports.Library_Loader;
