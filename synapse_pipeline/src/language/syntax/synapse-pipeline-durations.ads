--  A length of time as the language writes it: a whole number and a unit,
--  `90s`, `30m` or `2h`.

package Synapse.Pipeline.Durations is

   --  The longest duration there is: 30 days.
   Largest_Seconds : constant := 30 * 24 * 60 * 60;

   subtype Timeout_Seconds is Natural range 0 .. Largest_Seconds;

   --  The seconds Text stands for, or 0 for anything that is not a duration,
   --  is a duration of nothing or is longer than 30 days.
   function Seconds (Text : String) return Timeout_Seconds;

end Synapse.Pipeline.Durations;
