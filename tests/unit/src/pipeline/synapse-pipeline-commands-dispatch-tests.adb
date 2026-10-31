with AUnit.Assertions;

with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Dispatch.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure No_Arguments_Print_The_Usage_And_Return_Two
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "code 2");
      Assert
        (F.Base.Console.Err_Text = Usage.Text,
         "the usage, to standard error");
      Assert (F.Base.Console.Out_Text = "", "and nothing on standard output");
   end No_Arguments_Print_The_Usage_And_Return_Two;

   procedure Help_Prints_The_Usage_And_Succeeds (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--help")) = 0, "--help");
      Assert
        (F.Base.Console.Out_Text = Usage.Text
         and then F.Base.Console.Err_Text = "",
         "the usage, to standard output");
      Assert (Run (Env (F), Args ("-h")) = 0, "-h");
   end Help_Prints_The_Usage_And_Succeeds;

   procedure Every_Subcommand_Has_Its_Own_Help (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Says
        (Subcommand, Flag, Help : String)
      is
         F : aliased Fixture;
      begin
         Assert
           (Run (Env (F), Args (Subcommand, Flag)) = 0,
            Subcommand & " " & Flag & " succeeds");
         Assert
           (F.Base.Console.Out_Text = Help
            and then F.Base.Console.Err_Text = "",
            Subcommand & " says its own help, to standard output");
      end Says;
   begin
      Says ("check", "--help", Usage.Check_Help);
      Says ("run", "--help", Usage.Run_Help);
      Says ("list", "-h", Usage.List_Help);
      Says ("info", "--help", Usage.Info_Help);
   end Every_Subcommand_Has_Its_Own_Help;

   procedure A_Usage_Error_Prints_Only_The_Synopsis
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("list", "extra")) = 2, "code 2");
      Assert
        (F.Base.Console.Err_Text = "usage: synapse-pipeline list" & Usage.LF,
         "one line, not the whole help");
      Assert
        (Usage.Synopsis (Usage.Info_Help) =
         "usage: synapse-pipeline info <execution-id> [--format json|text] "
         & "[--query <rule>]" & Usage.LF,
         "a synopsis is the first line");
   end A_Usage_Error_Prints_Only_The_Synopsis;

   procedure An_Unknown_Subcommand_Is_Named_Before_The_Usage
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("frobnicate", "x")) = 2, "code 2");
      Assert
        (F.Base.Console.Err_Text =
         "synapse-pipeline: unknown subcommand 'frobnicate'" & Usage.LF
         & Usage.Text,
         "named, then the usage");
   end An_Unknown_Subcommand_Is_Named_Before_The_Usage;

   procedure A_Flag_Before_The_Subcommand_Is_Not_Its_Option
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert
        (Run (Env (F), Args ("--bogus", "help")) = 2,
         "only the first argument names the subcommand");
   end A_Flag_Before_The_Subcommand_Is_Not_Its_Option;

   procedure Check_Is_A_Subcommand (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("check")) = 2, "check without a name");
      Assert
        (F.Base.Console.Err_Text =
         "usage: synapse-pipeline check <pipeline>" & Usage.LF,
         "is the subcommand's own usage, not the unknown-name error");
   end Check_Is_A_Subcommand;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Dispatch");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, No_Arguments_Print_The_Usage_And_Return_Two'Access,
         "No arguments print the usage and return two");
      Register_Routine
        (T, Every_Subcommand_Has_Its_Own_Help'Access,
         "Every subcommand has its own help");
      Register_Routine
        (T, A_Usage_Error_Prints_Only_The_Synopsis'Access,
         "A usage error prints only the synopsis");
      Register_Routine
        (T, Help_Prints_The_Usage_And_Succeeds'Access,
         "Help prints the usage and succeeds");
      Register_Routine
        (T, An_Unknown_Subcommand_Is_Named_Before_The_Usage'Access,
         "An unknown subcommand is named before the usage");
      Register_Routine
        (T, A_Flag_Before_The_Subcommand_Is_Not_Its_Option'Access,
         "A flag before the subcommand is not its option");
      Register_Routine
        (T, Check_Is_A_Subcommand'Access, "Check is a subcommand");
   end Register_Tests;

end Synapse.Pipeline.Commands.Dispatch.Tests;
