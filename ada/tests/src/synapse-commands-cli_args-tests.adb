with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Test_Environment;

package body Synapse.Commands.Cli_Args.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure A_Value_Is_Taken_When_It_Does_Not_Look_Like_A_Flag
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      A     : constant Lists.Vector := Args ("--repo", "foo");
      Index : Positive              := 1;
      Value : Ada.Strings.Unbounded.Unbounded_String;
      Found : Boolean;
   begin
      Take_Value (A, Index, Value, Found);
      Assert
        (Found and then Ada.Strings.Unbounded.To_String (Value) = "foo",
         "an ordinary value");
      Assert (Index = 2, "the index moves onto the value");
   end A_Value_Is_Taken_When_It_Does_Not_Look_Like_A_Flag;

   procedure A_Value_That_Looks_Like_A_Flag_Is_Refused_So_Help_Is_Seen
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      A     : constant Lists.Vector := Args ("--repo", "--help");
      Index : Positive              := 1;
      Value : Ada.Strings.Unbounded.Unbounded_String;
      Found : Boolean;
   begin
      Take_Value (A, Index, Value, Found);
      Assert (not Found, "refused");
      Assert (Index = 2, "and consumed, as the caller is about to give up");
   end A_Value_That_Looks_Like_A_Flag_Is_Refused_So_Help_Is_Seen;

   procedure A_Single_Dash_Value_Is_Still_A_Value (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Index : Positive := 1;
      Value : Ada.Strings.Unbounded.Unbounded_String;
      Found : Boolean;
   begin
      Take_Value (Args ("--repo", "-"), Index, Value, Found);
      Assert
        (Found and then Ada.Strings.Unbounded.To_String (Value) = "-",
         "only two dashes make a flag");
   end A_Single_Dash_Value_Is_Still_A_Value;

   procedure No_Next_Argument_Is_Not_Found_And_Does_Not_Move
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Index : Positive := 1;
      Value : Ada.Strings.Unbounded.Unbounded_String;
      Found : Boolean;
   begin
      Take_Value (Args ("--repo"), Index, Value, Found);
      Assert (not Found and then Index = 1, "nothing to take");
   end No_Next_Argument_Is_Not_Found_And_Does_Not_Move;

   procedure The_Map_For_A_Subcommand_Goes_To_Standard_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Print_Map_For (Env (F), "callers");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Assert
        (F.Console.Err_Text
           (F.Console.Err_Text'First .. F.Console.Err_Text'First + 32) =
         Character'Val (10) & "Synapse commands by question:" &
         Character'Val (10) & "- ",
         "the heading, then the entries");
   end The_Map_For_A_Subcommand_Goes_To_Standard_Error;

   procedure A_Subcommand_The_Map_Does_Not_Cover_Prints_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Print_Map_For (Env (F), "vault-list");
      Assert (F.Console.Err_Text = "", "no heading with nothing under it");
   end A_Subcommand_The_Map_Does_Not_Cover_Prints_Nothing;

   procedure Help_Is_Dash_H_Or_Double_Dash_Help (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_Help ("-h") and then Is_Help ("--help"), "both");
      Assert
        (not Is_Help ("-help") and then not Is_Help ("help")
         and then not Is_Help (""),
         "nothing near them");
   end Help_Is_Dash_H_Or_Double_Dash_Help;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Cli_Args");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Value_Is_Taken_When_It_Does_Not_Look_Like_A_Flag'Access,
         "A value is taken when it does not look like a flag");
      Register_Routine
        (T, A_Value_That_Looks_Like_A_Flag_Is_Refused_So_Help_Is_Seen'Access,
         "A value that looks like a flag is refused");
      Register_Routine
        (T, A_Single_Dash_Value_Is_Still_A_Value'Access,
         "A single dash is still a value");
      Register_Routine
        (T, No_Next_Argument_Is_Not_Found_And_Does_Not_Move'Access,
         "No next argument is not found and does not move");
      Register_Routine
        (T, The_Map_For_A_Subcommand_Goes_To_Standard_Error'Access,
         "The map for a subcommand goes to standard error");
      Register_Routine
        (T, A_Subcommand_The_Map_Does_Not_Cover_Prints_Nothing'Access,
         "A subcommand the map does not cover prints nothing");
      Register_Routine
        (T, Help_Is_Dash_H_Or_Double_Dash_Help'Access, "Help is -h or --help");
   end Register_Tests;

end Synapse.Commands.Cli_Args.Tests;
