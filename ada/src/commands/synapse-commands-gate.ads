--  `gate`: the clusters of a vocabulary table that own no vocabulary of
--  their own. Advice and never a hard stop, so it always returns 0 when it
--  could judge; it needs no vault, namespace or checkout.
package Synapse.Commands.Gate is

   --  `gate --vocab <groupwords.tsv> [--parseable <parseable.tsv>] [--all]
   --  [--top N]`.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Gate;
