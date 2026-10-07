with Synapse.Core.Results;
--  Loading a compiled tree-sitter grammar through a Library_Loader.

with Synapse.Ports.Library_Loader;

package Synapse.Adapters.Tree_Sitter.Grammar with SPARK_Mode => Off is

   type Load_Error is
     (Library_Not_Found,
      Not_A_Library,
      Symbol_Not_Found,
      Abi_Unsupported);

   package Load_Results is new Synapse.Core.Results (Language, Load_Error);

   subtype Load_Result is Load_Results.Result;

   --  Opens the shared library at Path, calls its Symbol function (such as
   --  `tree_sitter_java`) and returns the language it yields. A language whose
   --  ABI is outside ABI_Min .. ABI_Max is refused here rather than failing
   --  later in Set_Language. The library stays loaded.
   function Load_Language
     (Loader : in out Synapse.Ports.Library_Loader.Loader'Class;
      Path   : String;
      Symbol : String) return Load_Result;

end Synapse.Adapters.Tree_Sitter.Grammar;
