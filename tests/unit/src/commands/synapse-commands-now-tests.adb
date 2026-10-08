with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Test_Environment;

package body Synapse.Commands.Now.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Now_Prints_The_Local_Time_With_No_Line_Feed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Clock.Now :=
        Ada.Strings.Unbounded.To_Unbounded_String
          ("2026-09-07T14:32:05+02:00");
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (F.Console.Out_Text = "2026-09-07T14:32:05+02:00",
         "exactly the time, no line feed");
      Assert (F.Console.Err_Text = "", "nothing on standard error");
   end Now_Prints_The_Local_Time_With_No_Line_Feed;

   procedure Built_At_Prints_The_Shorter_Shape (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Clock.Now :=
        Ada.Strings.Unbounded.To_Unbounded_String
          ("2026-09-07T14:32:05+02:00");
      Assert (Run (Env (F), Args ("--built-at")) = 0, "success");
      Assert (F.Console.Out_Text = "2026-09-07 14:32", "the built_at shape");
   end Built_At_Prints_The_Shorter_Shape;

   procedure Help_Prints_Usage_On_Standard_Error_And_Succeeds
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--help")) = 0, "help succeeds");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Assert
        (F.Console.Err_Text (1 .. 31) = "usage: synapse now [--built-at]",
         "the usage");
      Assert (Run (Env (F), Args ("-h")) = 0, "-h too");
   end Help_Prints_Usage_On_Standard_Error_And_Succeeds;

   procedure An_Unknown_Argument_Is_A_Usage_Error (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--wat")) = 2, "code 2");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Assert (F.Console.Err_Text'Length > 0, "the usage was printed");
   end An_Unknown_Argument_Is_A_Usage_Error;

   procedure A_Usage_Error_Stops_Before_Anything_Is_Printed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Clock.Now :=
        Ada.Strings.Unbounded.To_Unbounded_String
          ("2026-09-07T14:32:05+02:00");
      Assert (Run (Env (F), Args ("--built-at", "--wat")) = 2, "code 2");
      Assert (F.Console.Out_Text = "", "no time printed");
   end A_Usage_Error_Stops_Before_Anything_Is_Printed;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Now");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Now_Prints_The_Local_Time_With_No_Line_Feed'Access,
         "Now prints the local time with no line feed");
      Register_Routine
        (T, Built_At_Prints_The_Shorter_Shape'Access,
         "Built-at prints the shorter shape");
      Register_Routine
        (T, Help_Prints_Usage_On_Standard_Error_And_Succeeds'Access,
         "Help prints usage on standard error and succeeds");
      Register_Routine
        (T, An_Unknown_Argument_Is_A_Usage_Error'Access,
         "An unknown argument is a usage error");
      Register_Routine
        (T, A_Usage_Error_Stops_Before_Anything_Is_Printed'Access,
         "A usage error stops before anything is printed");
   end Register_Tests;

end Synapse.Commands.Now.Tests;
