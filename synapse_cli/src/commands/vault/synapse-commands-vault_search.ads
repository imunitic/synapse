--  `vault-search` and `vault-search-text`: finding notes by what they hold.
package Synapse.Commands.Vault_Search is

   --  `vault-search [--fields a,b]`, a JsonLogic rule on standard input: a row
   --  per matching note, its path then the asked for frontmatter fields.
   function Run_Search
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-search-text <query> [--namespace <repo>@<branch>] [--path-filter]`:
   --  `node<TAB>score<TAB>line ranges` for the best ten notes.
   function Run_Search_Text
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  The most notes `vault-search-text` prints.
   Row_Cap : constant := 10;

end Synapse.Commands.Vault_Search;
