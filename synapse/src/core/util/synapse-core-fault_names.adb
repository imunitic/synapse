with Ada.Strings.Unbounded;

package body Synapse.Core.Fault_Names is

   use Ada.Strings.Unbounded;

   function Camel (Image : String) return String is
      Result : Unbounded_String;
      Upper  : Boolean := True;
   begin
      for C of Image loop
         if C = '_' then
            Upper := True;
         elsif Upper then
            Append
              (Result,
               (if C in 'a' .. 'z' then Character'Val (Character'Pos (C) - 32)
                else C));
            Upper := False;
         else
            Append
              (Result,
               (if C in 'A' .. 'Z' then Character'Val (Character'Pos (C) + 32)
                else C));
         end if;
      end loop;
      return To_String (Result);
   end Camel;

   function Of_Exception
     (E : Ada.Exceptions.Exception_Occurrence) return String
   is
      Name  : constant String := Ada.Exceptions.Exception_Name (E);
      First : Positive        := Name'First;
   begin
      for I in reverse Name'Range loop
         if Name (I) = '.' then
            First := I + 1;
            exit;
         end if;
      end loop;
      return Camel (Name (First .. Name'Last));
   end Of_Exception;

end Synapse.Core.Fault_Names;
