--  The Library_Loader for the host operating system. The body is chosen by
--  the platform source directory: `dlopen` on POSIX systems, `LoadLibrary` on
--  Windows.

with System;

with Synapse.Ports.Library_Loader;

package Synapse.Adapters.Dynamic_Libraries is

   package Port renames Synapse.Ports.Library_Loader;

   type System_Loader is new Port.Loader with null record;

   overriding
   procedure Open
     (L      : in out System_Loader;
      Path   : String;
      Lib    : out Port.Library;
      Status : out Port.Open_Status);

   overriding
   function Symbol
     (L : System_Loader; Lib : Port.Library; Name : String)
      return System.Address;

   overriding
   function Extension (L : System_Loader) return String;

end Synapse.Adapters.Dynamic_Libraries;
