with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.Store_Contract;

package body Synapse.Adapters.Fake_Store.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Meets_The_Store_Contract (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : Fake_Store;
   begin
      Store_Contract.Check (S);
   end Meets_The_Store_Contract;

   procedure Counts_Its_Calls (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : Fake_Store;
   begin
      Assert (S.Write ("a", "1").Accepted, "write");
      Assert (S.Read ("a").Found, "read");
      Assert (not S.Read ("b").Found, "read missing");
      Assert (S.List.Length = 1, "list");
      Assert (S.Writes = 1 and then S.Reads = 2 and then S.Lists = 1,
              "counters");
   end Counts_Its_Calls;

   procedure A_Planted_Failure_Hits_Only_The_Next_Call
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S      : Fake_Store;
      Raised : Boolean := False;
   begin
      S.Fail_Next := True;
      begin
         declare
            Ignore : constant Port.Maybe_Text := S.Read ("a");
         begin
            null;
         end;
      exception
         when Port.Store_Failure =>
            Raised := True;
      end;
      Assert (Raised, "the next call fails");
      Assert (not S.Fail_Next, "and clears the failure");
      Assert (S.Write ("a", "1").Accepted, "then it works");
   end A_Planted_Failure_Hits_Only_The_Next_Call;

   procedure Search_Is_A_Plain_Case_Sensitive_Substring
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : Fake_Store;
   begin
      Assert (S.Write ("a.md", "a widget here").Accepted, "a");
      Assert (S.Write ("b.md", "nothing").Accepted, "b");
      declare
         Hits : constant Port.Hit_Vectors.Vector := S.Search ("widget");
      begin
         Assert (Hits.Length = 1, "one hit");
         Assert (To_String (Hits (1).Node) = "a.md"
                 and then Hits (1).Score = 1.0
                 and then To_String (Hits (1).Context) = "a widget here",
                 "its node, score and context");
      end;
      Assert (S.Search ("WIDGET").Is_Empty, "case matters");
   end Search_Is_A_Plain_Case_Sensitive_Substring;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Fake_Store");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Meets_The_Store_Contract'Access, "Meets the store contract");
      Register_Routine (T, Counts_Its_Calls'Access, "Counts its calls");
      Register_Routine
        (T, A_Planted_Failure_Hits_Only_The_Next_Call'Access,
         "A planted failure hits only the next call");
      Register_Routine
        (T, Search_Is_A_Plain_Case_Sensitive_Substring'Access,
         "Search is a plain case-sensitive substring");
   end Register_Tests;

end Synapse.Adapters.Fake_Store.Tests;
