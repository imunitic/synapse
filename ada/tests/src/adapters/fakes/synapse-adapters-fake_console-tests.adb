with AUnit.Assertions;

package body Synapse.Adapters.Fake_Console.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure What_Is_Written_Is_Kept_Per_Stream_And_Byte_For_Byte
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake;
   begin
      F.Write_Out ("one");
      F.Write_Err ("err");
      F.Write_Out (Character'Val (10) & "two" & Character'Val (0));
      Assert
        (F.Out_Text = "one" & Character'Val (10) & "two" & Character'Val (0),
         "out: nothing added or dropped");
      Assert (F.Err_Text = "err", "err is separate");
   end What_Is_Written_Is_Kept_Per_Stream_And_Byte_For_Byte;

   procedure Standard_Input_Is_What_Was_Given_And_Empty_Otherwise
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake;
   begin
      Assert (F.Read_Stdin = "", "nothing given");
      F.Set_Stdin ("a" & Character'Val (10) & "b");
      Assert (F.Read_Stdin = "a" & Character'Val (10) & "b", "as given");
      Assert
        (F.Read_Stdin = "a" & Character'Val (10) & "b",
         "readable again: a test may ask twice");
   end Standard_Input_Is_What_Was_Given_And_Empty_Otherwise;

   procedure Clear_Forgets_Both_Streams_And_Keeps_The_Input
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake;
   begin
      F.Write_Out ("out");
      F.Write_Err ("err");
      F.Set_Stdin ("in");
      F.Clear;
      Assert (F.Out_Text = "" and then F.Err_Text = "", "both streams empty");
      Assert (F.Read_Stdin = "in", "the input stays");
      F.Write_Out ("again");
      Assert (F.Out_Text = "again", "writing goes on");
   end Clear_Forgets_Both_Streams_And_Keeps_The_Input;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Fake_Console");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, What_Is_Written_Is_Kept_Per_Stream_And_Byte_For_Byte'Access,
         "What is written is kept per stream and byte for byte");
      Register_Routine
        (T, Standard_Input_Is_What_Was_Given_And_Empty_Otherwise'Access,
         "Standard input is what was given, and empty otherwise");
      Register_Routine
        (T, Clear_Forgets_Both_Streams_And_Keeps_The_Input'Access,
         "Clear forgets both streams and keeps the input");
   end Register_Tests;

end Synapse.Adapters.Fake_Console.Tests;
