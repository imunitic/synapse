--  Comparing a string against a fixed piece of text.

package Synapse.Core.String_Match is

   --  Whether S begins with Prefix. An empty Prefix begins every string.
   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

end Synapse.Core.String_Match;
