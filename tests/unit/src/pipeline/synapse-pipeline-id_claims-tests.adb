with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Fake_Registry;

package body Synapse.Pipeline.Id_Claims.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  The ids Draw gives, in order, then "last" for ever.
   Script : array (1 .. 4) of Unbounded_String;
   Drawn  : Natural := 0;

   function Draw return String is
   begin
      Drawn := Drawn + 1;
      return To_String (Script (Natural'Min (Drawn, Script'Last)));
   end Draw;

   procedure Prepare (A, B, C, D : String := "") is
   begin
      Drawn := 0;
      Script :=
        [To_Unbounded_String (A), To_Unbounded_String (B),
         To_Unbounded_String (C), To_Unbounded_String (D)];
   end Prepare;

   procedure A_Free_Id_Is_Claimed_At_Once (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Registry.Fake_Registry;
      C : Claim;
   begin
      Prepare ("exec-1", "exec-2", "exec-3", "exec-4");
      C := Take (F, Draw'Access);
      Assert
        (C.Registered and then To_String (C.Id) = "exec-1" and then Drawn = 1,
         "the first id is taken");
      Assert (F.Held.Contains ("exec-1"), "and its directory is made");
   end A_Free_Id_Is_Claimed_At_Once;

   procedure A_Taken_Id_Is_Not_Used (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Registry.Fake_Registry;
      C : Claim;
   begin
      Assert (F.Create ("exec-1") = Registry_Store.Created, "taken already");
      Assert (F.Create ("exec-2") = Registry_Store.Created, "and another");
      Prepare ("exec-1", "exec-2", "exec-3", "exec-4");
      C := Take (F, Draw'Access);
      Assert
        (C.Registered and then To_String (C.Id) = "exec-3" and then Drawn = 3,
         "the third id, which was free, is the one claimed: "
         & To_String (C.Id));
   end A_Taken_Id_Is_Not_Used;

   procedure Every_Id_Taken_Gives_Up_Without_A_Record
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Registry.Fake_Registry;
      C : Claim;
   begin
      Assert (F.Create ("exec-1") = Registry_Store.Created, "taken already");
      Prepare ("exec-1", "exec-1", "exec-1", "exec-1");
      C := Take (F, Draw'Access);
      Assert
        (not C.Registered and then Drawn = Largest_Tries,
         "it stops after the most tries");
      Assert (Length (C.Id) > 0, "and the run still has an id");
   end Every_Id_Taken_Gives_Up_Without_A_Record;

   procedure A_Directory_That_Cannot_Be_Made_Is_Not_Tried_Again
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Registry.Fake_Registry;
      C : Claim;
   begin
      F.Fail (Fake_Registry.Create_Op);
      Prepare ("exec-1", "exec-2", "exec-3", "exec-4");
      C := Take (F, Draw'Access);
      Assert
        (not C.Registered and then To_String (C.Id) = "exec-1"
         and then Drawn = 1,
         "a failure is not a taken id, so no other id is drawn");
   end A_Directory_That_Cannot_Be_Made_Is_Not_Tried_Again;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Id_Claims");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Free_Id_Is_Claimed_At_Once'Access,
         "A free id is claimed at once");
      Register_Routine
        (T, A_Taken_Id_Is_Not_Used'Access, "A taken id is not used");
      Register_Routine
        (T, Every_Id_Taken_Gives_Up_Without_A_Record'Access,
         "Every id taken gives up without a record");
      Register_Routine
        (T, A_Directory_That_Cannot_Be_Made_Is_Not_Tried_Again'Access,
         "A directory that cannot be made is not tried again");
   end Register_Tests;

end Synapse.Pipeline.Id_Claims.Tests;
