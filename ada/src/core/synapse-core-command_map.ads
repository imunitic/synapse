--  Which `synapse` command answers which question about a codebase: one
--  definition, rendered by `synapse context` and by the session start hook, so
--  the command and the injected text cannot disagree. Injected once a session
--  and not learned in each one: a session that does not know `query symbol` or
--  `callers --all` exists finds them only by running `--help`, and every such
--  discovery turn reads the whole context again.

package Synapse.Core.Command_Map is

   Count : constant := 13;

   subtype Entry_Index is Positive range 1 .. Count;

   --  What is wanted.
   function Question_Of (I : Entry_Index) return String;

   --  The command that answers it, as it would be typed.
   function Command_Of (I : Entry_Index) return String;

   --  The top-level subcommand the command runs, checked against the dispatch
   --  table so an entry cannot name a subcommand that is gone.
   function Sub_Of (I : Entry_Index) return String;

   --  `Synapse commands by question:` and one `- question: `command`` line
   --  each.
   function Render return String;

   --  Only the lines of the entries that run Sub: what a usage error for that
   --  subcommand prints. Empty when no entry runs it.
   function Render_For (Sub : String) return String;

end Synapse.Core.Command_Map;
