with AUnit.Assertions;

package body Synapse.Core.Fence_Languages.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure An_Empty_Registry_Gives_A_Bare_Fence (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Empty : constant Registry := Parse ("{}");
   begin
      Assert (Language_For (Empty, "x/thing.wdg") = "", "nothing is built in");
      Assert (Language_For (Empty, "") = "", "empty path");
   end An_Empty_Registry_Gives_A_Bare_Fence;

   procedure A_Registry_Maps_By_Extension_And_Is_Authoritative
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Registry :=
        Parse ("{"".wdg"": ""widget"", "".gdg"": ""gadget"", "".x"": 3}");
   begin
      Assert (Language_For (R, "a/b.wdg") = "widget", "first");
      Assert (Language_For (R, "a/b.gdg") = "gadget", "second");
      Assert (Language_For (R, "a/b.other") = "", "unmapped");
      Assert
        (Language_For (R, "a/b.x") = "",
         "a value that is not text is left out");
      Assert (Language_For (R, "a/b.wdg.bak") = "", "only a suffix counts");
      Assert (Natural (R.Entries.Length) = 2, "two entries");
   end A_Registry_Maps_By_Extension_And_Is_Authoritative;

   procedure The_First_Matching_Entry_In_File_Order_Wins
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Registry :=
        Parse ("{"".b.wdg"": ""first"", "".wdg"": ""second""}");
   begin
      Assert (Language_For (R, "x.b.wdg") = "first", "file order");
      Assert (Language_For (R, "x.a.wdg") = "second", "and the other");
   end The_First_Matching_Entry_In_File_Order_Wins;

   procedure Something_That_Is_Not_An_Object_Is_Empty_And_Bad_Json_Is_An_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      Assert (Parse ("[]").Entries.Is_Empty, "an array");
      begin
         declare
            Ignore : constant Registry := Parse ("not json");
         begin
            null;
         end;
      exception
         when Malformed =>
            Raised := True;
      end;
      Assert (Raised, "a load error and not a silent fallback");
   end Something_That_Is_Not_An_Object_Is_Empty_And_Bad_Json_Is_An_Error;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Fence_Languages");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Empty_Registry_Gives_A_Bare_Fence'Access,
         "An empty registry gives a bare fence");
      Register_Routine
        (T, A_Registry_Maps_By_Extension_And_Is_Authoritative'Access,
         "A registry maps by extension");
      Register_Routine
        (T, The_First_Matching_Entry_In_File_Order_Wins'Access,
         "The first matching entry in file order wins");
      Register_Routine
        (T,
         Something_That_Is_Not_An_Object_Is_Empty_And_Bad_Json_Is_An_Error'
           Access,
         "Something that is not an object is empty and bad JSON is an error");
   end Register_Tests;

end Synapse.Core.Fence_Languages.Tests;
