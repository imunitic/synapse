with AUnit.Assertions;

package body Synapse.Core.Doctor.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Make
     (Name : String; State : Status; Detail : String := "") return Check is
     (Name   => To_Unbounded_String (Name), State => State,
      Detail => To_Unbounded_String (Detail));

   procedure A_Warning_Never_Fails_The_Command_And_A_Failure_Always_Does
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Warned, Failed, None : Check_Vectors.Vector;
   begin
      Warned.Append (Make ("a", Ok));
      Warned.Append (Make ("b", Warn));
      Failed.Append (Make ("a", Ok));
      Failed.Append (Make ("b", Fail));
      Assert (Exit_Code (Warned) = 0, "warnings are exit 0");
      Assert (Exit_Code (Failed) = 1, "a failure is exit 1");
      Assert (Exit_Code (None) = 0, "nothing checked is not a failure");
   end A_Warning_Never_Fails_The_Command_And_A_Failure_Always_Does;

   procedure The_Report_Puts_The_Status_First_And_Aligns_The_Details
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Checks : Check_Vectors.Vector;
   begin
      Checks.Append (Make ("vault", Ok, "/Users/x/Vault/Claude"));
      Checks.Append (Make ("namespace", Warn, "none for fw-core@wip"));
      Checks.Append (Make ("certificate", Fail, "absent: run setup-cert.sh"));
      Assert
        (Report (Checks) =
         "ok    vault        /Users/x/Vault/Claude" & LF &
         "warn  namespace    none for fw-core@wip" & LF &
         "FAIL  certificate  absent: run setup-cert.sh" & LF & LF &
         "1 ok, 1 warning(s), 1 failure(s)" & LF,
         "the report");
   end The_Report_Puts_The_Status_First_And_Aligns_The_Details;

   procedure A_Check_With_No_Detail_Prints_Only_Its_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Checks : Check_Vectors.Vector;
   begin
      Checks.Append (Make ("git", Ok));
      Assert
        (Report (Checks) =
         "ok    git" & LF & LF & "1 ok, 0 warning(s), 0 failure(s)" & LF,
         "no trailing padding");
   end A_Check_With_No_Detail_Prints_Only_Its_Name;

   procedure An_Empty_Report_Is_Just_The_Totals (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      None : Check_Vectors.Vector;
   begin
      Assert
        (Report (None) = LF & "0 ok, 0 warning(s), 0 failure(s)" & LF,
         "empty");
   end An_Empty_Report_Is_Just_The_Totals;

   procedure Counts_Are_Kept_Per_Level (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Checks : Check_Vectors.Vector;
   begin
      Checks.Append (Make ("a", Ok));
      Checks.Append (Make ("b", Ok));
      Checks.Append (Make ("c", Warn));
      Checks.Append (Make ("d", Fail));
      Checks.Append (Make ("e", Fail));
      Checks.Append (Make ("f", Fail));
      Assert
        (Count (Checks).Ok = 2 and then Count (Checks).Warn = 1
         and then Count (Checks).Fail = 3,
         "2, 1, 3");
   end Counts_Are_Kept_Per_Level;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Doctor");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Warning_Never_Fails_The_Command_And_A_Failure_Always_Does'Access,
         "A warning never fails the command and a failure always does");
      Register_Routine
        (T, The_Report_Puts_The_Status_First_And_Aligns_The_Details'Access,
         "The report puts the status first and aligns the details");
      Register_Routine
        (T, A_Check_With_No_Detail_Prints_Only_Its_Name'Access,
         "A check with no detail prints only its name");
      Register_Routine
        (T, An_Empty_Report_Is_Just_The_Totals'Access,
         "An empty report is just the totals");
      Register_Routine
        (T, Counts_Are_Kept_Per_Level'Access, "Counts are kept per level");
   end Register_Tests;

end Synapse.Core.Doctor.Tests;
