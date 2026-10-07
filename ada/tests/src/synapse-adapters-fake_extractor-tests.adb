with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Graph_Model;

package body Synapse.Adapters.Fake_Extractor.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Port.Outcome_Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Paths_Of (A, B, C : String := "") return Core.Text_Lists.Vector is
      Result : Core.Text_Lists.Vector;
   begin
      if A /= "" then
         Result.Append (To_Unbounded_String (A));
      end if;
      if B /= "" then
         Result.Append (To_Unbounded_String (B));
      end if;
      if C /= "" then
         Result.Append (To_Unbounded_String (C));
      end if;
      return Result;
   end Paths_Of;

   function One_Tag (Name : String) return Port.Outcome is
      Result : Port.Outcome := (Kind => Port.With_Tags, others => <>);
   begin
      Result.Tags.Append
        (Core.Graph_Model.Tag'
           (Name       => To_Unbounded_String (Name),
            Kind       => To_Unbounded_String ("function"),
            Which      => Core.Graph_Model.Def, Line => 0,
            Expression => To_Unbounded_String (Name)));
      return Result;
   end One_Tag;

   procedure Outcomes_Come_Back_One_Per_Path_In_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake;
   begin
      F.Script ("a.ext", One_Tag ("a"));
      F.Script ("b.ext", (Kind => Port.Unsupported));
      declare
         Got : constant Port.Outcome_Vectors.Vector :=
           F.Extract (".", Paths_Of ("a.ext", "b.ext", "c.ext"));
      begin
         Assert (Natural (Got.Length) = 3, "one each");
         Assert
           (Got (1).Kind = Port.With_Tags
            and then Natural (Got (1).Tags.Length) = 1,
            "scripted tags");
         Assert (Got (2).Kind = Port.Unsupported, "scripted unsupported");
         Assert
           (Got (3).Kind = Port.With_Tags and then Got (3).Tags.Is_Empty,
            "the default: tagged with none");
      end;
   end Outcomes_Come_Back_One_Per_Path_In_Order;

   procedure The_Default_Can_Be_Changed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake;
   begin
      F.Set_Default ((Kind => Port.Unsupported));
      Assert
        (F.Extract (".", Paths_Of ("x")) (1).Kind = Port.Unsupported,
         "unsupported by default");
   end The_Default_Can_Be_Changed;

   procedure A_Batch_Is_One_Call_And_Every_Path_Is_Recorded
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F      : Fake;
      Ignore : Port.Outcome_Vectors.Vector;
   begin
      Ignore := F.Extract (".", Paths_Of ("a", "b", "c"));
      Assert (F.Calls = 1, "one call for the whole batch");
      Assert
        (Natural (F.Seen.Length) = 3
         and then To_String (F.Seen.Element (2)) = "b",
         "every path, in order");
      Ignore := F.Extract (".", Paths_Of ("d"));
      Assert
        (F.Calls = 2 and then Natural (F.Seen.Length) = 4,
         "and the next call adds to both");
   end A_Batch_Is_One_Call_And_Every_Path_Is_Recorded;

   procedure An_Empty_Batch_Is_An_Empty_Answer (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake;
   begin
      Assert
        (F.Extract (".", Paths_Of).Is_Empty, "nothing asked, nothing back");
      Assert (F.Calls = 1, "still a call");
   end An_Empty_Batch_Is_An_Empty_Answer;

   procedure A_Later_Script_Replaces_An_Earlier_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake;
   begin
      F.Script ("a", One_Tag ("old"));
      F.Script ("a", (Kind => Port.Unsupported));
      Assert
        (F.Extract (".", Paths_Of ("a")) (1).Kind = Port.Unsupported,
         "the last wins");
   end A_Later_Script_Replaces_An_Earlier_One;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Fake_Extractor");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Outcomes_Come_Back_One_Per_Path_In_Order'Access,
         "Outcomes come back one per path, in order");
      Register_Routine
        (T, The_Default_Can_Be_Changed'Access, "The default can be changed");
      Register_Routine
        (T, A_Batch_Is_One_Call_And_Every_Path_Is_Recorded'Access,
         "A batch is one call and every path is recorded");
      Register_Routine
        (T, An_Empty_Batch_Is_An_Empty_Answer'Access,
         "An empty batch is an empty answer");
      Register_Routine
        (T, A_Later_Script_Replaces_An_Earlier_One'Access,
         "A later script replaces an earlier one");
   end Register_Tests;

end Synapse.Adapters.Fake_Extractor.Tests;
