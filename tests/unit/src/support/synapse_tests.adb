with Ada.Command_Line;

with AUnit.Reporter.Text;
with AUnit.Run;

with Test_Suites;

procedure Synapse_Tests is
   function Run is new AUnit.Run.Test_Runner_With_Status (Test_Suites.Suite);
   Reporter : AUnit.Reporter.Text.Text_Reporter;
   use type AUnit.Status;
begin
   if Run (Reporter) /= AUnit.Success then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Synapse_Tests;
