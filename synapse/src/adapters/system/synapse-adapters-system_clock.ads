with Synapse.Ports.Clock;

--  The operating system's clock and its local time zone.

package Synapse.Adapters.System_Clock is

   type System_Clock is limited new Synapse.Ports.Clock.Clock with null record;

   overriding
   function Timestamp (C : System_Clock) return String;

   --  The same formatting for a given instant and offset in minutes, which
   --  is what Timestamp does with the current ones.
   function Format
     (Year, Month, Day, Hour, Minute, Second : Natural;
      Offset_Minutes                         : Integer) return String;

end Synapse.Adapters.System_Clock;
