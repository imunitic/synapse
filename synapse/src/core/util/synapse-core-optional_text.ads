with Ada.Strings.Unbounded;

with Synapse.Core.Options;

--  Text that may be absent: the one option of text every lookup of a string
--  answers with.
package Synapse.Core.Optional_Text is new Synapse.Core.Options
  (Ada.Strings.Unbounded.Unbounded_String);
