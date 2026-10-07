with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Commands.Usage;
with Synapse.Test_Environment;

package body Synapse.Commands.Dispatch.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Ends_With (Text, Suffix : String) return Boolean is
     (Text'Length >= Suffix'Length
      and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix);

   procedure No_Arguments_Print_The_Usage_And_Return_Two
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "code 2");
      Assert (F.Console.Err_Text = Usage.Text, "the usage, to standard error");
      Assert (F.Console.Out_Text = "", "and nothing on standard output");
   end No_Arguments_Print_The_Usage_And_Return_Two;

   procedure Help_Prints_The_Usage_And_Succeeds (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--help")) = 0, "--help");
      Assert (F.Console.Err_Text = Usage.Text, "the usage");
      Assert (Run (Env (F), Args ("-h")) = 0, "-h");
   end Help_Prints_The_Usage_And_Succeeds;

   procedure An_Unknown_Subcommand_Is_Named_Before_The_Usage
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("frobnicate", "x")) = 2, "code 2");
      Assert
        (F.Console.Err_Text =
         "synapse: unknown subcommand 'frobnicate'" & LF & Usage.Text,
         "named, then the usage");
   end An_Unknown_Subcommand_Is_Named_Before_The_Usage;

   procedure A_Subcommand_Gets_The_Rest_Of_The_Arguments
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Clock.Now :=
        Ada.Strings.Unbounded.To_Unbounded_String
          ("2026-09-07T14:32:05+02:00");
      Assert (Run (Env (F), Args ("now", "--built-at")) = 0, "now --built-at");
      Assert
        (F.Console.Out_Text = "2026-09-07 14:32",
         "the program name and the subcommand are not its arguments");
   end A_Subcommand_Gets_The_Rest_Of_The_Arguments;

   procedure A_Flag_Before_The_Subcommand_Is_Not_Its_Option
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert
        (Run (Env (F), Args ("--built-at", "now")) = 2,
         "only the first argument names the subcommand");
   end A_Flag_Before_The_Subcommand_Is_Not_Its_Option;

   procedure Every_Name_In_The_Table_Is_Listed_In_The_Usage
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for I in 1 .. Count loop
         --  What a write starts in the background is not typed by a person.
         if Name_Of (I) = "vault-git-pusher" then
            Assert
              (Ada.Strings.Fixed.Index (Usage.Text, Name_Of (I)) = 0,
               Name_Of (I) & " is left out of the usage");
         else
            Assert
              (Ada.Strings.Fixed.Index
                 (Usage.Text, LF & "  " & Name_Of (I)) > 0,
               Name_Of (I) & " has a line in the usage");
         end if;
         Assert (Find (Name_Of (I)) /= null, Name_Of (I) & " is found");
      end loop;
   end Every_Name_In_The_Table_Is_Listed_In_The_Usage;

   procedure Find_Is_Exact_And_Null_For_A_Stranger
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Find ("nowx") = null and then Find ("") = null
         and then Find ("NOW") = null and then Find ("-h") = null,
         "no near misses");
   end Find_Is_Exact_And_Null_For_A_Stranger;

   procedure The_Usage_Starts_The_Way_Callers_Expect
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Ada.Strings.Fixed.Index
           (Usage.Text, "usage: synapse <subcommand> [args]" & LF & LF) =
         1,
         "the first line");
      Assert
        (Ends_With (Usage.Text, "on demand" & LF),
         "one line feed at the end, after the last subcommand");
   end The_Usage_Starts_The_Way_Callers_Expect;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Dispatch");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, No_Arguments_Print_The_Usage_And_Return_Two'Access,
         "No arguments print the usage and return two");
      Register_Routine
        (T, Help_Prints_The_Usage_And_Succeeds'Access,
         "Help prints the usage and succeeds");
      Register_Routine
        (T, An_Unknown_Subcommand_Is_Named_Before_The_Usage'Access,
         "An unknown subcommand is named before the usage");
      Register_Routine
        (T, A_Subcommand_Gets_The_Rest_Of_The_Arguments'Access,
         "A subcommand gets the rest of the arguments");
      Register_Routine
        (T, A_Flag_Before_The_Subcommand_Is_Not_Its_Option'Access,
         "A flag before the subcommand is not its option");
      Register_Routine
        (T, Every_Name_In_The_Table_Is_Listed_In_The_Usage'Access,
         "Every name in the table is listed in the usage");
      Register_Routine
        (T, Find_Is_Exact_And_Null_For_A_Stranger'Access,
         "Find is exact and null for a stranger");
      Register_Routine
        (T, The_Usage_Starts_The_Way_Callers_Expect'Access,
         "The usage starts the way callers expect");
   end Register_Tests;

end Synapse.Commands.Dispatch.Tests;
