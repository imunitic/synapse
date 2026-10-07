--  The small unanchored matcher behind the vault search `regexp` operator.
--
--  Grammar: a literal, `.` (any one character, newline included), and one of
--  `*` `+` `?` after an atom; `^` as the first character of the pattern and
--  `$` as the last. Everything else is a literal, a backslash included.
--  Matching is greedy with back-off, over code points: text and pattern are
--  read as UTF-8, and a byte that is not part of a well-formed sequence is a
--  character of its own.

package Synapse.Core.Regex_Lite with SPARK_Mode is

   --  Too_Complex: the match gave up after Step_Limit steps, which a pattern
   --  such as `a*a*a*a*b` over a long run of `a` reaches.
   type Outcome is (Matched, Not_Matched, Too_Complex);

   Step_Limit : constant := 1_000_000;

   --  Whether Pattern matches anywhere in Text, or only at its start when it
   --  begins with `^`.
   function Search (Pattern, Text : String) return Outcome
   with Pre => Pattern'Last < Positive'Last and then Text'Last < Positive'Last;

end Synapse.Core.Regex_Lite;
