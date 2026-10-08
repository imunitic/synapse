--  Bytes written as hexadecimal text, for fixtures that must be independent
--  of the code under test.

package Synapse.Test_Bytes is

   --  The bytes of a string of hexadecimal digit pairs.
   function From_Hex (Hex : String) return String;

   --  The same, in lowercase.
   function To_Hex (Bytes : String) return String;

end Synapse.Test_Bytes;
