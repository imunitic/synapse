--  `synapse now`: the machine's local time in the two shapes a write needs, so
--  a caller has no reason left to ask a subprocess for the date.
--
--    now              RFC 3339, `2026-09-07T14:32:05+02:00`: what `created`
--                     and `updated` take
--    now --built-at   `2026-09-07 14:32`: what `built_at` takes
--
--  No line feed follows the value: a caller substituting it into another value
--  should not have to strip one.

package Synapse.Commands.Now is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Now;
