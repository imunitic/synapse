--  Names a grammar's repository and its entry point share.

package Synapse.Core.Grammar_Names with SPARK_Mode is

   Repo_Prefix   : constant String := "tree-sitter-";
   Symbol_Prefix : constant String := "tree_sitter_";

   Max_Name_Length : constant := 4096;

   function Has_Repo_Prefix (Name : String) return Boolean
   is (Name'Length >= Repo_Prefix'Length
       and then
         Name (Name'First .. Name'First + Repo_Prefix'Length - 1)
         = Repo_Prefix)
   with Pre => Name'Last < Positive'Last;

   --  The C function a grammar exports: `tree-sitter-foo-bar` becomes
   --  `tree_sitter_foo_bar`; a name without the repository prefix gets the
   --  symbol prefix added, with its '-' still replaced.
   function Symbol_For (Repo_Name : String) return String
   with
     Pre  =>
       Repo_Name'Last < Positive'Last
       and then Repo_Name'Length <= Max_Name_Length,
     Post =>
       Symbol_For'Result'First = 1
       and then
         Symbol_For'Result'Length
         = (if Has_Repo_Prefix (Repo_Name)
            then Repo_Name'Length
            else Repo_Name'Length + Symbol_Prefix'Length)
       and then
         Symbol_For'Result (1 .. Symbol_Prefix'Length) = Symbol_Prefix;

end Synapse.Core.Grammar_Names;
