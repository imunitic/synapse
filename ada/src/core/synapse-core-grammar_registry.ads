with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Core.JSON;

--  What the grammar registry says about an extension: whether a grammar is
--  usable for it, where it comes from and which query file backs its tags.
--  The registry is a JSON object keyed by extension without the dot. It ships
--  empty and an entry is written only after a grammar is checked against a
--  real file of the repository it is for.

package Synapse.Core.Grammar_Registry is

   use Ada.Strings.Unbounded;

   Malformed : exception;

   --  The query file an extension's tags come from: `tags.scm`, `locals.scm`,
   --  or a query written from the grammar's own `node-types.json`. Override
   --  is never recorded in the registry: a person's own query file for the
   --  extension, found at run time, always wins over every other source.
   type Query_Source is (Tags, Locals, Generated, Override);

   type Readiness_Kind is (Ready,
      --  Registered but marked `unsupported`, or missing its repository or
      --  scope: a final answer.
      Unusable,
      --  Not registered: a prompt to find a grammar and try again.
      No_Entry);

   type Readiness (Kind : Readiness_Kind := No_Entry) is record
      case Kind is
         when Ready =>
            Scope  : Unbounded_String;
            Source : Query_Source;

         when Unusable | No_Entry =>
            null;
      end case;
   end record;

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   type Registry is private;

   --  The registry a JSON object describes. Anything but an object has no
   --  entry. Raises Malformed when the text is not JSON.
   function Parse (Text : String) return Registry;

   function Lookup (R : Registry; Extension : String) return Readiness;

   --  The queries field: `tags` when absent, so an entry written before the
   --  field existed needs no change, `locals` or `generated`. A value that is
   --  not one of these falls back to `tags` and does not refuse an entry
   --  whose repository and scope passed.
   function Source_Of (R : Registry; Extension : String) return Query_Source;

   --  The clone URL of an entry.
   function Repo_For (R : Registry; Extension : String) return Maybe_Text;

   --  The directory holding `src/parser.c`, for a repository shipping more
   --  than one grammar. None means the repository root. Each grammar of such
   --  a repository is its own entry naming the same repository.
   function Path_For (R : Registry; Extension : String) return Maybe_Text;

   --  The `tree_sitter_*` symbol to look up when it cannot be derived from
   --  the repository name. None means derive it with Symbol_For.
   function Symbol_For (R : Registry; Extension : String) return Maybe_Text;

   --  The extension of a path, lowercased, or empty for a name that has none.
   --  A leading dot makes an extension (`.hidden` is `hidden`); a trailing
   --  one makes none. Only ASCII letters are lowercased.
   function Extension_Of (Path : String) return String;

   --  The symbol a grammar repository derives its language function from:
   --  the name without a leading `tree-sitter-`, with `-` as `_`, after
   --  `tree_sitter_`.
   function Symbol_For (Repo_Name : String) return String;

   --  The last segment of a clone URL without a trailing `/` or `.git`.
   function Repo_Name_Of (Url : String) return String;

private

   type Registry is record
      Root : Core.JSON.Value;
   end record;

end Synapse.Core.Grammar_Registry;
