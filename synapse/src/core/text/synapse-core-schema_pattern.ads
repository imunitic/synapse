--  The bounded regular-expression dialect of note schemas.
--
--  Grammar: a literal, `.`, a character class `[abc]` / `[a-z]` / `[^...]`
--  (escapes allowed inside), one of `*` `+` `?` `{n}` `{n,}` `{n,m}` after an
--  atom, `^` as the first character and `$` as the last. An escape is valid
--  only before a character that is special here, so `\d` is refused. Groups,
--  alternation, captures and backreferences are refused. Matching is
--  greedy with back-off, over code points: text and pattern are read as
--  UTF-8, and a byte that is not part of a well-formed sequence is a
--  character of its own.

with Synapse.Core.Regex_Lite;

package Synapse.Core.Schema_Pattern with SPARK_Mode is

   type Fault is
     (None,
      Invalid_Escape,
      Unterminated_Class,
      Empty_Class,
      Invalid_Quantifier,
      Unsupported_Construct);

   --  The first fault in Pattern's syntax, or None.
   function Validate (Pattern : String) return Fault
   with Pre => Pattern'Last < Positive'Last;

   --  Whether a valid Pattern matches anywhere in Text, or only at its start
   --  when it begins with `^`. Too_Complex: the match gave up after
   --  Regex_Lite.Step_Limit steps.
   function Search
     (Pattern, Text : String) return Regex_Lite.Outcome
   with
     Pre =>
       Pattern'Last < Positive'Last
       and then Text'Last < Positive'Last
       and then Validate (Pattern) = None;

end Synapse.Core.Schema_Pattern;
