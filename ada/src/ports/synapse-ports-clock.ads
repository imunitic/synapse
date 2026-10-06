--  The time of day, as the machine reads it. Passed in, so everything that
--  stamps a note is testable with a fixed clock.

package Synapse.Ports.Clock is

   type Clock is limited interface;

   --  The local time as RFC 3339 with a numeric, colon-separated offset
   --  (`YYYY-MM-DDTHH:MM:SS+02:00`, `Z` for UTC): the shape a `timestamp`
   --  field takes and the instants of two offsets compare by.
   function Timestamp (C : Clock) return String is abstract;

end Synapse.Ports.Clock;
