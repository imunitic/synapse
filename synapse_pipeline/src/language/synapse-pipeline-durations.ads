--  A length of time as the language writes it: a whole number and a unit,
--  `90s`, `30m` or `2h`.

package Synapse.Pipeline.Durations is

   --  The seconds Text stands for, or 0 for anything that is not a duration
   --  or is a duration of nothing.
   function Seconds (Text : String) return Natural;

end Synapse.Pipeline.Durations;
