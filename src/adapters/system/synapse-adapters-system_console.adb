with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

package body Synapse.Adapters.System_Console is

   --  Writes every byte, whatever a write call takes of them at once. A
   --  failed write ends it: a closed pipe is the reader's business.
   procedure Write_All (FD : GNAT.OS_Lib.File_Descriptor; Text : String) is
      Done : Natural := 0;
   begin
      while Done < Text'Length loop
         declare
            Wrote : constant Integer :=
              GNAT.OS_Lib.Write
                (FD, Text (Text'First + Done)'Address, Text'Length - Done);
         begin
            exit when Wrote <= 0;
            Done := Done + Wrote;
         end;
      end loop;
   end Write_All;

   overriding procedure Write_Out (C : in out System_Console; Text : String) is
      pragma Unreferenced (C);
   begin
      Write_All (GNAT.OS_Lib.Standout, Text);
   end Write_Out;

   overriding procedure Write_Err (C : in out System_Console; Text : String) is
      pragma Unreferenced (C);
   begin
      Write_All (GNAT.OS_Lib.Standerr, Text);
   end Write_Err;

   overriding function Read_Stdin (C : in out System_Console) return String is
      pragma Unreferenced (C);
      Block  : String (1 .. 65_536);
      Result : Ada.Strings.Unbounded.Unbounded_String;
   begin
      loop
         declare
            Got : constant Integer :=
              GNAT.OS_Lib.Read
                (GNAT.OS_Lib.Standin, Block'Address, Block'Length);
         begin
            exit when Got <= 0;
            Ada.Strings.Unbounded.Append (Result, Block (1 .. Got));
         end;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Read_Stdin;

end Synapse.Adapters.System_Console;
