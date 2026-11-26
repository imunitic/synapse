with Test_Selection;
with Test_Suites;

procedure Synapse_Acceptance is
   procedure Run is new Test_Selection.Run_Suite (Test_Suites.Suite);
begin
   Run;
end Synapse_Acceptance;
