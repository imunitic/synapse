package body Synapse.Adapters.Fake_Console is

   use Ada.Strings.Unbounded;

   procedure Set_Stdin (F : in out Fake; Text : String) is
   begin
      F.Input := To_Unbounded_String (Text);
   end Set_Stdin;

   function Out_Text (F : Fake) return String is (To_String (F.Written));

   function Err_Text (F : Fake) return String is (To_String (F.Errors));

   overriding procedure Write_Out (F : in out Fake; Text : String) is
   begin
      Append (F.Written, Text);
   end Write_Out;

   overriding procedure Write_Err (F : in out Fake; Text : String) is
   begin
      Append (F.Errors, Text);
   end Write_Err;

   overriding function Read_Stdin (F : in out Fake) return String is
     (To_String (F.Input));

end Synapse.Adapters.Fake_Console;
