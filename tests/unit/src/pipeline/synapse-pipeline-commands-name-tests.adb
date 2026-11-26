with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Name.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   procedure Set_Up (F : in out Fixture) is
   begin
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (F.Registry.Create ("exec-a") = Registry_Store.Created, "made");
   end Set_Up;

   --  The name the registry holds for Id, or "(none)".
   function Name_Of (F : Fixture; Id : String) return String is
      Held : constant Registry_Store.Maybe_Content :=
        F.Registry.Read_Name (Id);
   begin
      return (if Held.Found then To_String (Held.Value) else "(none)");
   end Name_Of;

   procedure A_Name_Is_Set (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("exec-a", "Fix login")) = 0, "it succeeds");
      Assert
        (Name_Of (F, "exec-a") = "Fix login",
         "the run has the name: " & Name_Of (F, "exec-a"));
      Assert
        (F.Base.Console.Out_Text = "" and then F.Base.Console.Err_Text = "",
         "and nothing is printed");
   end A_Name_Is_Set;

   procedure A_Name_Is_Replaced (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("exec-a", "Fix login")) = 0, "first");
      Assert (Run (Env (F), Args ("exec-a", "Second try")) = 0, "second");
      Assert
        (Name_Of (F, "exec-a") = "Second try",
         "the new name replaces the old: " & Name_Of (F, "exec-a"));
   end A_Name_Is_Replaced;

   procedure No_Text_Clears_The_Name (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("exec-a", "Fix login")) = 0, "named");
      Assert (Run (Env (F), Args ("exec-a")) = 0, "cleared");
      Assert
        (Name_Of (F, "exec-a") = "(none)",
         "the run has no name: " & Name_Of (F, "exec-a"));
      Assert
        (Run (Env (F), Args ("exec-a")) = 0,
         "clearing a run with no name succeeds too");
   end No_Text_Clears_The_Name;

   procedure An_Unknown_Execution_Is_An_Error (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("exec-z", "Fix login")) = 1, "exit 1");
      Assert
        (F.Base.Console.Err_Text = "error: no execution exec-z" & LF,
         "it says which: " & F.Base.Console.Err_Text);
      Assert
        (Run (Env (F), Args ("../exec-a", "Fix login")) = 1,
         "an id that is not a plain name is not an execution");
      Assert (Name_Of (F, "exec-a") = "(none)", "and nothing is named");
   end An_Unknown_Execution_Is_An_Error;

   procedure A_Name_With_A_Line_Feed_Is_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("exec-a", "Fix" & LF & "login")) = 2, "exit 2");
      Assert (Name_Of (F, "exec-a") = "(none)", "and nothing is named");
   end A_Name_With_A_Line_Feed_Is_A_Usage_Error;

   procedure Three_Arguments_Are_A_Usage_Error (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("exec-a", "Fix", "login")) = 2, "three: exit 2");
      Assert (Run (Env (F), Args) = 2, "none: exit 2");
      Assert (Name_Of (F, "exec-a") = "(none)", "and nothing is named");
   end Three_Arguments_Are_A_Usage_Error;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Name");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, A_Name_Is_Set'Access, "A name is set");
      Register_Routine (T, A_Name_Is_Replaced'Access, "A name is replaced");
      Register_Routine
        (T, No_Text_Clears_The_Name'Access, "No text clears the name");
      Register_Routine
        (T, An_Unknown_Execution_Is_An_Error'Access,
         "An unknown execution is an error");
      Register_Routine
        (T, A_Name_With_A_Line_Feed_Is_A_Usage_Error'Access,
         "A name with a line feed is a usage error");
      Register_Routine
        (T, Three_Arguments_Are_A_Usage_Error'Access,
         "Three arguments are a usage error");
   end Register_Tests;

end Synapse.Pipeline.Commands.Name.Tests;
