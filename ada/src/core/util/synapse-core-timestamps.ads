--  The two shapes of local time a note carries.

package Synapse.Core.Timestamps is

   --  `YYYY-MM-DD HH:MM`, no seconds and no offset: the shape of `built_at`,
   --  which is a string with a pattern and not a timestamp, so nothing
   --  compares it across a change of offset. From an RFC 3339 time such as
   --  `2026-09-07T14:32:05+02:00`, whose own digits it keeps: it does not
   --  convert, so it is the same local time.
   function Built_At (Rfc3339 : String) return String with
     Pre => Rfc3339'Length >= 16, Post => Built_At'Result'Length = 16;

end Synapse.Core.Timestamps;
