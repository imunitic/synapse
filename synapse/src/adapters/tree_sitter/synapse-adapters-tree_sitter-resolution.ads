with Ada.Strings.Unbounded;

with Synapse.Core.Grammar_Registry;
with Synapse.Ports.Library_Loader;
with Synapse.Ports.Process_Runner;

--  From an extension to a loaded language, through the registry: look the
--  extension up, clone the grammar's repository if it is not already, build
--  it and load it. The one sequence every consumer of a grammar needs,
--  whatever it then does with a parse: the tagger and the docstring pairing
--  both start here, and only the first goes on to read a query.

package Synapse.Adapters.Tree_Sitter.Resolution with
  SPARK_Mode => Off
is

   use Ada.Strings.Unbounded;

   type Kind is (Resolved,
      --  No entry in the registry: a prompt to find a grammar, not a failure.
      Not_Registered,
      --  An entry marked unsupported, or missing what it needs.
      Not_Usable,
      --  Registered and usable, but cloning, building or loading it failed.
      Failed);

   type Resolution (Which : Kind := Not_Registered) is record
      case Which is
         when Resolved =>
            Lang     : Language;
            --  The clone, where the grammar's queries are.
            Repo_Dir : Unbounded_String;
            Scope    : Unbounded_String;
            Source   : Core.Grammar_Registry.Query_Source;

         when Failed =>
            --  What happened, in full, for a person.
            Detail : Unbounded_String;

         when Not_Registered | Not_Usable =>
            null;
      end case;
   end record;

   function Resolve
     (Run       : in out Synapse.Ports.Process_Runner.Runner'Class;
      Loader    : in out Synapse.Ports.Library_Loader.Loader'Class;
      Registry  :        Core.Grammar_Registry.Registry; Grammars_Dir : String;
      Extension :        String; Max_Tries : Positive;
      --  Look the extension up and clone its repository, but neither build
      --  nor load the grammar: Lang is then No_Language.
      Skip_Load :        Boolean := False) return Resolution;

end Synapse.Adapters.Tree_Sitter.Resolution;
