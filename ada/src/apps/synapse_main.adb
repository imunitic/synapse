with Ada.Text_IO;

with Synapse_Config;

procedure Synapse_Main is
begin
   Ada.Text_IO.Put_Line ("synapse " & Synapse_Config.Crate_Version);
end Synapse_Main;
