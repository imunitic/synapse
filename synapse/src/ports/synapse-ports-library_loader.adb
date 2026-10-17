package body Synapse.Ports.Library_Loader is

   function To_Library (Handle : System.Address) return Library
   is (Handle => Handle);

   function Handle_Of (Lib : Library) return System.Address
   is (Lib.Handle);

end Synapse.Ports.Library_Loader;
