--  `synapse namespace`: the namespace key of a checkout.
--
--    namespace [--repo <dir>]   `{repo}@{branch}`
--    namespace --branch         the branch half, sanitized
--    namespace --repo-name      the repository half
--
--  Two callers need the derivation and should not repeat it: a test helper
--  that builds fixture paths from it, and a person debugging an install who
--  wants to see what it resolved to. Exit 1 outside a repository or on a
--  detached HEAD: no branch is no namespace, which is an answer and not a
--  failure. No line feed follows the value, since callers put it in a path.

package Synapse.Commands.Namespace is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Namespace;
