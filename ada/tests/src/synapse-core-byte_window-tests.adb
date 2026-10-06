with AUnit.Assertions;

with Synapse.Ports.Byte_Source;

package body Synapse.Core.Byte_Window.Tests is

   use AUnit.Assertions;
   use Ports.Byte_Source;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  A source that counts how often it is read.
   type Counting_Source is limited new Source with record
      Reads : Natural := 0;
   end record;

   overriding function Size (S : in out Counting_Source) return Offset is
     (200_000);

   overriding function Read
     (S : in out Counting_Source; From : Offset; Count : Positive)
      return String
   is
      Last   : constant Offset := Offset'Min (200_000, From + Offset (Count));
      Result : String (1 .. Natural (Offset'Max (0, Last - From)));
   begin
      S.Reads := S.Reads + 1;
      for I in Result'Range loop
         Result (I) := Character'Val ((From + Offset (I - 1)) mod 251);
      end loop;
      return Result;
   end Read;

   procedure Reads_Inside_The_Block_Do_Not_Touch_The_Source
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Src : Counting_Source;
      W   : Window;
   begin
      Assert
        (Read (W, Src, 10, 4) =
         Character'Val (10) & Character'Val (11) & Character'Val (12) &
         Character'Val (13),
         "the bytes");
      for I in 1 .. 100 loop
         declare
            Ignore : constant String :=
              Read (W, Src, Offset (10 + I * 50), 43);
         begin
            null;
         end;
      end loop;
      Assert (Src.Reads = 1, "one block served a hundred reads");
   end Reads_Inside_The_Block_Do_Not_Touch_The_Source;

   procedure A_Read_Outside_The_Block_Loads_Another
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Src : Counting_Source;
      W   : Window;
      A   : constant String := Read (W, Src, 0, 4);
      B   : constant String := Read (W, Src, 100_000, 4);
      C   : constant String := Read (W, Src, 2, 4);
   begin
      Assert
        (A'Length = 4 and then B'Length = 4 and then C'Length = 4,
         "each is whole");
      Assert (Character'Pos (B (1)) = 100_000 mod 251, "from where asked");
      Assert (Character'Pos (C (1)) = 2, "and back again");
      Assert (Src.Reads = 3, "a block each time it moves");
   end A_Read_Outside_The_Block_Loads_Another;

   procedure A_Read_That_Ends_Exactly_At_The_Block_End_Is_Served
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Src : Counting_Source;
      W   : Window;
      A   : constant String := Read (W, Src, 0, 4);
      B   : constant String := Read (W, Src, Default_Block - 4, 4);
   begin
      Assert (A'Length = 4 and then B'Length = 4, "both whole");
      Assert (Src.Reads = 1, "the last bytes of the block need no new read");
   end A_Read_That_Ends_Exactly_At_The_Block_End_Is_Served;

   procedure A_Read_Larger_Than_A_Block_Is_Whole (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Src : Counting_Source;
      W   : Window;
      Big : constant String := Read (W, Src, 5, 100_000);
   begin
      Assert (Big'Length = 100_000, "all of it");
      Assert
        (Character'Pos (Big (Big'Last)) = (5 + 99_999) mod 251,
         "to the last byte");
   end A_Read_Larger_Than_A_Block_Is_Whole;

   procedure The_End_Of_The_Source_Gives_Fewer_Or_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Src : Counting_Source;
      W   : Window;
   begin
      Assert (Read (W, Src, 199_998, 10)'Length = 2, "fewer at the end");
      Assert (Read (W, Src, 199_999, 1)'Length = 1, "the last byte");
      Assert (Read (W, Src, 200_000, 5)'Length = 0, "none at the end");
      Assert (Read (W, Src, 300_000, 5)'Length = 0, "none past it");
   end The_End_Of_The_Source_Gives_Fewer_Or_None;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Byte_Window");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Reads_Inside_The_Block_Do_Not_Touch_The_Source'Access,
         "Reads inside the block do not touch the source");
      Register_Routine
        (T, A_Read_Outside_The_Block_Loads_Another'Access,
         "A read outside the block loads another");
      Register_Routine
        (T, A_Read_That_Ends_Exactly_At_The_Block_End_Is_Served'Access,
         "A read that ends exactly at the block end is served");
      Register_Routine
        (T, A_Read_Larger_Than_A_Block_Is_Whole'Access,
         "A read larger than a block is whole");
      Register_Routine
        (T, The_End_Of_The_Source_Gives_Fewer_Or_None'Access,
         "The end of the source gives fewer or none");
   end Register_Tests;

end Synapse.Core.Byte_Window.Tests;
