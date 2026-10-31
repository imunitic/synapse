--  `synapse-pipeline info <execution-id> [--format json|text]
--  [--query <rule>]`: what a running pipeline says about itself.
--
--  Without `--query` it is the run in brief. With one, the JsonLogic rule is
--  evaluated over the run by the run itself and its answer is printed; the
--  rule may ask for anything the run reports, such as `{"var": "state"}`.
--  The format is `text`, the default, for a person, and `json` for a program;
--  the answer to a query is the JSON value, with a string as it is in text.

package Synapse.Pipeline.Commands.Info is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Info;
