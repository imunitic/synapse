with Ada.Strings.Unbounded;

package body Synapse.Core.Command_Map is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Question_Of (I : Entry_Index) return String is
     (case I is when 1 => "what a node is and what it links to, in brief",
        when 2 =>
          "a node's whole prose and crux code, only when the brief does " &
          "not answer",
        when 3 => "which node mentions a word, as line ranges to read next",
        when 4 => "specific lines of a node, e.g. a search's ranges",
        when 5 => "which files a node covers",
        when 6 => "which node owns a file",
        when 7 => "where a symbol is defined",
        when 8 => "every definition and reference of a name, repo-wide",
        when 9 => "who calls a name",
        when 10 => "what a node links to, or what links to it",
        when 11 => "whether files changed under the graph",
        when 12 => "what changed since each node's commit",
        when others => "another branch's graph");

   function Command_Of (I : Entry_Index) return String is
     (case I is when 1 => "synapse query body ""<node>""",
        when 2 => "synapse query body ""<node>"" --full",
        when 3 =>
          "synapse vault-search-text ""<words>"" --namespace <repo>@<branch>",
        when 4 => "synapse query body ""<node>"" --lines <a-b>[,<c-d>]",
        when 5 => "synapse query sources ""<node>""",
        when 6 => "synapse index lookup <path>",
        when 7 => "synapse query symbol <name> ""<node>""",
        when 8 => "synapse callers <name> --all",
        when 9 => "synapse callers <name>",
        when 10 => "synapse query links ""<node>"" [--inbound]",
        when 11 => "synapse query stale", when 12 => "synapse query drift",
        when others =>
          "add --namespace <repo>@<branch> to query, index lookup or callers");

   function Sub_Of (I : Entry_Index) return String is
     (case I is when 1 => "query", when 2 => "query",
        when 3 => "vault-search-text", when 4 => "query", when 5 => "query",
        when 6 => "index", when 7 => "query", when 8 => "callers",
        when 9 => "callers", when 10 => "query", when 11 => "query",
        when 12 => "query", when others => "query");

   function Line_Of (I : Entry_Index) return String is
     ("- " & Question_Of (I) & ": `" & Command_Of (I) & "`" & LF);

   function Render return String is
      Text : Unbounded_String :=
        To_Unbounded_String ("Synapse commands by question:" & LF);
   begin
      for I in Entry_Index loop
         Append (Text, Line_Of (I));
      end loop;
      return To_String (Text);
   end Render;

   function Render_For (Sub : String) return String is
      Text : Unbounded_String;
   begin
      for I in Entry_Index loop
         if Sub_Of (I) = Sub then
            Append (Text, Line_Of (I));
         end if;
      end loop;
      return To_String (Text);
   end Render_For;

end Synapse.Core.Command_Map;
