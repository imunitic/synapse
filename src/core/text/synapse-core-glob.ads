--  The `glob` operator's matcher. `*` matches any run of characters, slashes
--  included, so `designs/*` matches `designs/synapse/note.md`. Every other
--  character is literal. A pattern with no trailing `*` must reach the end of
--  the text, and an empty pattern matches only empty text.

package Synapse.Core.Glob with SPARK_Mode is

   function Glob_Match (Pattern, Text : String) return Boolean
   with Pre => Pattern'Last < Positive'Last and then Text'Last < Positive'Last;

end Synapse.Core.Glob;
