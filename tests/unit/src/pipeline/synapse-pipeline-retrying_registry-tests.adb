with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Fake_Registry;
with Synapse.Pipeline.Registry_Contract;

package body Synapse.Pipeline.Retrying_Registry.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;
   use type Fake_Registry.Operation;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  What was waited and what was said, since the last Reset.
   Waited : Natural := 0;
   Total  : Duration := 0.0;
   Longest : Duration := 0.0;
   Said   : Unbounded_String;
   Said_Count : Natural := 0;

   procedure Reset is
   begin
      Waited := 0;
      Total := 0.0;
      Longest := 0.0;
      Said := Null_Unbounded_String;
      Said_Count := 0;
   end Reset;

   procedure Wait (Seconds : Duration) is
   begin
      Waited := Waited + 1;
      Total := Total + Seconds;
      Longest := Seconds;
   end Wait;

   procedure Say (Message : String) is
   begin
      Said_Count := Said_Count + 1;
      Said := To_Unbounded_String (Message);
   end Say;

   procedure It_Meets_The_Contract (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Inner : aliased Fake_Registry.Fake_Registry;
      R     : Retrying_Registry (Inner'Access, Wait'Access, Say'Access);
   begin
      Reset;
      Registry_Contract.Check (R, "x");
      Assert
        (Said_Count = 1 and then Index (Said, "execution x-b") > 0,
         "the writes the contract makes to an execution that was never made "
         & "are the only ones given up, and are said once: "
         & To_String (Said));
   end It_Meets_The_Contract;

   procedure A_Write_That_Fails_Briefly_Is_Tried_Again
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Inner : aliased Fake_Registry.Fake_Registry;
      R     : Retrying_Registry (Inner'Access, Wait'Access, Say'Access);
   begin
      Reset;
      Assert (R.Create ("a") = Registry_Store.Created, "made");
      Inner.Fail (Fake_Registry.Replace_Op, Times => 2);
      Assert (R.Replace_Summary ("a", "ok"), "it gets through");
      Assert
        (Inner.Attempts (Fake_Registry.Replace_Op) = 3,
         "on the third attempt");
      Assert
        (Waited = 2 and then Total = 0.030 and then Longest = 0.020,
         "after waiting 10 ms and then 20 ms");
      Assert (Said_Count = 0, "and nothing is said");
   end A_Write_That_Fails_Briefly_Is_Tried_Again;

   procedure A_Write_That_Keeps_Failing_Is_Given_Up_With_One_Warning
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Inner : aliased Fake_Registry.Fake_Registry;
      R     : Retrying_Registry (Inner'Access, Wait'Access, Say'Access);
   begin
      Reset;
      Assert (R.Create ("a") = Registry_Store.Created, "made");
      Inner.Fail (Fake_Registry.Append_Op);
      Assert (not R.Append_Event ("a", "e"), "the write fails");
      Assert
        (Inner.Attempts (Fake_Registry.Append_Op) = Attempts,
         "after every attempt");
      Assert
        (Waited = Attempts - 1 and then Total = 0.150 and then Longest = 0.080,
         "waiting 10, 20, 40 and 80 ms between them");
      Assert
        (Said_Count = 1
         and then Index (Said, "execution a") > 0
         and then Index (Said, "an event") > 0,
         "and it is said once: " & To_String (Said));
      Assert (not R.Append_Event ("a", "f"), "the next write fails too");
      Assert
        (Inner.Attempts (Fake_Registry.Append_Op) = 2 * Attempts,
         "with attempts of its own");
      Assert (Said_Count = 1, "and nothing more is said for that execution");
      Assert (R.Create ("b") = Registry_Store.Created, "another one");
      Assert (not R.Append_Event ("b", "e"), "fails as well");
      Assert (Said_Count = 2, "and it is said for that one");
   end A_Write_That_Keeps_Failing_Is_Given_Up_With_One_Warning;

   procedure A_Failure_That_Passes_Does_Not_End_The_Record
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Inner : aliased Fake_Registry.Fake_Registry;
      R     : Retrying_Registry (Inner'Access, Wait'Access, Say'Access);
   begin
      Reset;
      Assert (R.Create ("a") = Registry_Store.Created, "made");
      Inner.Fail (Fake_Registry.Transcript_Op);
      Assert
        (not R.Write_Transcript ("a", "S-1", "t"), "a write is given up");
      Inner.Mend (Fake_Registry.Transcript_Op);
      Assert
        (R.Write_Transcript ("a", "S-2", "t"),
         "the disk comes back and the next write is kept");
      Assert (Natural (R.Transcript_Names ("a").Length) = 1, "only that one");
   end A_Failure_That_Passes_Does_Not_End_The_Record;

   procedure A_Taken_Id_Is_Not_Tried_Again (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Inner : aliased Fake_Registry.Fake_Registry;
      R     : Retrying_Registry (Inner'Access, Wait'Access, Say'Access);
   begin
      Reset;
      Assert (R.Create ("a") = Registry_Store.Created, "made");
      Assert
        (R.Create ("a") = Registry_Store.Already_Exists,
         "a second create finds it taken");
      Assert
        (Inner.Attempts (Fake_Registry.Create_Op) = 2
         and then Waited = 0 and then Said_Count = 0,
         "once, with no wait and no warning");
      Inner.Fail (Fake_Registry.Create_Op, Times => 2);
      Assert
        (R.Create ("b") = Registry_Store.Created
         and then Inner.Attempts (Fake_Registry.Create_Op) = 5,
         "a create that fails is tried again");
      Inner.Fail (Fake_Registry.Create_Op);
      Assert
        (R.Create ("c") = Registry_Store.Failed and then Said_Count = 1,
         "and given up, with a warning");
   end A_Taken_Id_Is_Not_Tried_Again;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Retrying_Registry");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, It_Meets_The_Contract'Access, "It meets the registry contract");
      Register_Routine
        (T, A_Write_That_Fails_Briefly_Is_Tried_Again'Access,
         "A write that fails briefly is tried again");
      Register_Routine
        (T, A_Write_That_Keeps_Failing_Is_Given_Up_With_One_Warning'Access,
         "A write that keeps failing is given up with one warning");
      Register_Routine
        (T, A_Failure_That_Passes_Does_Not_End_The_Record'Access,
         "A failure that passes does not end the record");
      Register_Routine
        (T, A_Taken_Id_Is_Not_Tried_Again'Access,
         "A taken id is not tried again");
   end Register_Tests;

end Synapse.Pipeline.Retrying_Registry.Tests;
