with Ada.Characters.Conversions;

package body Synapse.Pipeline.Win32 is

   function Wide (Text : String) return C.wchar_array is
   begin
      return C.To_C (Ada.Characters.Conversions.To_Wide_String (Text));
   end Wide;

   function Narrow (Text : C.wchar_array) return String is
   begin
      return Ada.Characters.Conversions.To_String (C.To_Ada (Text));
   exception
      when others =>
         return "";
   end Narrow;

end Synapse.Pipeline.Win32;
