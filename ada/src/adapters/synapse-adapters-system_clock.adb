with Ada.Calendar;
with Ada.Calendar.Time_Zones;

package body Synapse.Adapters.System_Clock is

   function Two (N : Natural) return String is
      Text : constant String := Natural'Image (N + 100);
   begin
      return Text (Text'Last - 1 .. Text'Last);
   end Two;

   function Format
     (Year, Month, Day, Hour, Minute, Second : Natural;
      Offset_Minutes                         : Integer) return String
   is
      Year_Text : constant String := Natural'Image (Year + 10_000);
      Zone      : constant String :=
        (if Offset_Minutes = 0 then "Z"
         else (if Offset_Minutes < 0 then "-" else "+")
              & Two (abs Offset_Minutes / 60) & ":"
              & Two (abs Offset_Minutes mod 60));
   begin
      return
        Year_Text (Year_Text'Last - 3 .. Year_Text'Last) & "-" & Two (Month)
        & "-" & Two (Day) & "T" & Two (Hour) & ":" & Two (Minute) & ":"
        & Two (Second) & Zone;
   end Format;

   overriding
   function Timestamp (C : System_Clock) return String is
      pragma Unreferenced (C);
      Now     : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Year    : Ada.Calendar.Year_Number;
      Month   : Ada.Calendar.Month_Number;
      Day     : Ada.Calendar.Day_Number;
      Seconds : Ada.Calendar.Day_Duration;
      Whole   : Natural;
   begin
      Ada.Calendar.Split (Now, Year, Month, Day, Seconds);
      Whole := Natural (Seconds - 0.5);
      if Seconds < 0.5 then
         Whole := 0;
      end if;
      return
        Format
          (Natural (Year), Natural (Month), Natural (Day), Whole / 3600,
           Whole / 60 mod 60, Whole mod 60,
           Integer (Ada.Calendar.Time_Zones.UTC_Time_Offset (Now)));
   end Timestamp;

end Synapse.Adapters.System_Clock;
