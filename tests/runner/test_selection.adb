with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Text_IO;

with AUnit;
with AUnit.Options;
with AUnit.Reporter.Text;
with AUnit.Run;
with AUnit.Simple_Test_Cases;
with AUnit.Test_Results;

package body Test_Selection is

   use Ada.Strings.Unbounded;

   function Parse (Argument, Variable : String) return Selection is
      Text : constant String :=
        (if Argument'Length > 0 then Argument else Variable);
   begin
      if Text'Length = 0 then
         return (Mode => Run_All, Filter => Null_Unbounded_String);
      elsif Text = "--list" then
         return (Mode => List_Names, Filter => Null_Unbounded_String);
      else
         return (Mode => Run_Filtered, Filter => To_Unbounded_String (Text));
      end if;
   end Parse;

   function From_Command_Line return Selection is
   begin
      return Parse
        (Argument =>
           (if Ada.Command_Line.Argument_Count = 0 then ""
            else Ada.Command_Line.Argument (1)),
         Variable =>
           Ada.Environment_Variables.Value ("SYNAPSE_TEST_FILTER", ""));
   end From_Command_Line;

   function Full_Name (T : AUnit.Tests.Test'Class) return String is
      use type AUnit.Message_String;
   begin
      if T not in AUnit.Simple_Test_Cases.Test_Case'Class then
         return "";
      end if;
      declare
         Test : AUnit.Simple_Test_Cases.Test_Case'Class renames
           AUnit.Simple_Test_Cases.Test_Case'Class (T);
         Name    : constant AUnit.Message_String := Test.Name;
         Routine : constant AUnit.Message_String := Test.Routine_Name;
      begin
         if Name = null then
            return "";
         elsif Routine = null then
            return Name.all;
         else
            return Name.all & " : " & Routine.all;
         end if;
      end;
   end Full_Name;

   overriding function Is_Active
     (Filter : Listing_Filter; T : AUnit.Tests.Test'Class) return Boolean
   is
      pragma Unreferenced (Filter);
   begin
      Ada.Text_IO.Put_Line (Full_Name (T));
      return False;
   end Is_Active;

   function Failed
     (Mode : Mode_Kind; Ran : Natural; Successful : Boolean) return Boolean
   is
   begin
      return not Successful or else (Mode = Run_Filtered and then Ran = 0);
   end Failed;

   procedure Run_Suite is
      procedure Run is new AUnit.Run.Test_Runner_With_Results (Suite);

      Chosen   : constant Selection := From_Command_Line;
      Names    : aliased AUnit.Test_Filters.Name_Filter;
      Listing  : aliased Listing_Filter;
      Options  : AUnit.Options.AUnit_Options := AUnit.Options.Default_Options;
      Reporter : AUnit.Reporter.Text.Text_Reporter;
      Result   : AUnit.Test_Results.Result;
   begin
      case Chosen.Mode is
         when Run_All =>
            null;
         when Run_Filtered =>
            Names.Set_Name (To_String (Chosen.Filter));
            Options.Filter := Names'Unchecked_Access;
         when List_Names =>
            Options.Filter := Listing'Unchecked_Access;
      end case;

      Run (Reporter, Result, Options);

      declare
         Ran : constant Natural :=
           Natural (AUnit.Test_Results.Test_Count (Result));
      begin
         if Failed (Chosen.Mode, Ran, AUnit.Test_Results.Successful (Result))
         then
            if Chosen.Mode = Run_Filtered and then Ran = 0 then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "no test matches " & To_String (Chosen.Filter));
            end if;
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;
   end Run_Suite;

end Test_Selection;
