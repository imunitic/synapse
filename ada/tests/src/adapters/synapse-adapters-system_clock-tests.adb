with AUnit.Assertions;

with Synapse.Core.Note_Text;

package body Synapse.Adapters.System_Clock.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Formatting_Pads_And_Signs_The_Offset (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Format (2026, 9, 7, 15, 0, 5, 0) = "2026-09-07T15:00:05Z",
              "UTC is Z");
      Assert (Format (2026, 9, 7, 15, 0, 5, 120) = "2026-09-07T15:00:05+02:00",
              "east");
      Assert (Format (2026, 9, 7, 15, 0, 5, -330)
              = "2026-09-07T15:00:05-05:30", "west, half an hour");
      Assert (Format (987, 1, 2, 3, 4, 5, 60) = "0987-01-02T03:04:05+01:00",
              "a short year is padded");
      Assert (Format (2026, 12, 31, 23, 59, 59, -60)
              = "2026-12-31T23:59:59-01:00", "the end of the year");
   end Formatting_Pads_And_Signs_The_Offset;

   procedure The_Real_Clock_Gives_A_Valid_Timestamp
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      C     : System_Clock;
      Value : constant String := C.Timestamp;
   begin
      Assert (Core.Note_Text.Valid_Timestamp (Value),
              "an RFC 3339 timestamp: " & Value);
      Assert (Value'Length = 20 or else Value'Length = 25, "Z or an offset");
   end The_Real_Clock_Gives_A_Valid_Timestamp;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.System_Clock");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Formatting_Pads_And_Signs_The_Offset'Access,
         "Formatting pads and signs the offset");
      Register_Routine
        (T, The_Real_Clock_Gives_A_Valid_Timestamp'Access,
         "The real clock gives a valid timestamp");
   end Register_Tests;

end Synapse.Adapters.System_Clock.Tests;
